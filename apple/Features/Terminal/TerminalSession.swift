import Foundation
import Observation
import SSHCoreBridge

struct ConnectionTarget: Equatable, Sendable {
  var displayName: String
  var host: String
  var port: UInt16
  var username: String
  var usesPrivateKey: Bool

  var title: String { displayName.isEmpty ? host : displayName }
  func hasSameIdentity(as other: Self) -> Bool {
    host.lowercased() == other.host.lowercased() && port == other.port
      && username == other.username && usesPrivateKey == other.usesPrivateKey
  }
}

struct HostKeyChallenge: Identifiable {
  let id: UUID
  let target: ConnectionTarget
  let algorithm: String
  let fingerprint: String
}

@MainActor @Observable
final class TerminalSession {
  let id: UUID
  let target: ConnectionTarget
  let sourceHostID: UUID?
  let isConnectionTest: Bool
  private(set) var state: SessionState = .connecting
  private(set) var failure: FailureCode?
  private(set) var endReason: DisconnectReason?
  private(set) var exitStatus: UInt32?
  private(set) var isSuspended = false
  private(set) var isCheckingConnection = false
  @ObservationIgnored private var recovery: Task<Void, Never>?
  @ObservationIgnored private var recoveryOperation: RemoteOperation?
  @ObservationIgnored private var lifecycleRevision = 0
  private(set) var receivedBytes = 0
  private(set) var columns: UInt32 = 80
  private(set) var rows: UInt32 = 24
  var localErrorKey: String?
  var onHostKey: ((HostKeyChallenge) -> Void)?
  var onEnded: ((UUID) -> Void)?
  var onConnected: (() -> Void)?
  var onFocus: (() -> Void)?
  private(set) var testSucceeded = false
  private(set) var files: RemoteFilesModel?
  private(set) var monitor: ServerMonitorModel?
  @ObservationIgnored private var connection: SshConnection?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var pendingInput = Data()
  @ObservationIgnored private var terminalSurface: TerminalSurface?
  @ObservationIgnored private var receivedEnd = false

  init(
    id: UUID, target: ConnectionTarget, sourceHostID: UUID? = nil, isConnectionTest: Bool = false
  ) {
    self.id = id
    self.target = target
    self.sourceHostID = sourceHostID
    self.isConnectionTest = isConnectionTest
  }

  deinit {
    connection?.disconnect()
    polling?.cancel()
    recovery?.cancel()
    recoveryOperation?.cancel()
  }

  var surface: TerminalSurface {
    if let terminalSurface { return terminalSurface }
    let created = TerminalSurface(session: self)
    terminalSurface = created
    return created
  }

  var isConnected: Bool { state == .connected && !isSuspended && !isCheckingConnection }
  var isActive: Bool {
    return switch state {
    case .connecting, .verifyingHostKey, .authenticating, .connected, .disconnecting: true
    case .disconnected, .failed: false
    }
  }
  var statusKey: String {
    if isCheckingConnection { return "ssh.state.checkingConnection" }
    if isSuspended { return "ssh.state.background" }
    if isConnectionTest && testSucceeded && state == .disconnected { return "hosts.testSucceeded" }
    return switch state {
    case .connecting: "ssh.state.connecting"
    case .verifyingHostKey: "ssh.state.verifying"
    case .authenticating: "ssh.state.authenticating"
    case .connected: "ssh.state.connected"
    case .disconnecting: "ssh.state.disconnecting"
    case .disconnected: endReason == .remote ? "ssh.state.remoteClosed" : "ssh.state.disconnected"
    case .failed: "ssh.state.failed"
    }
  }

  func connect(authentication: AuthenticationRequest, trustedFingerprint: String?) {
    do {
      let connection = try SshConnection(
        request: ConnectionRequest(
          host: target.host, port: target.port, username: target.username,
          trustedFingerprint: trustedFingerprint, columns: columns, rows: rows, timeoutSeconds: 20),
        authentication: authentication)
      self.connection = connection
      if !isConnectionTest {
        files = RemoteFilesModel(connection: connection)
        monitor = ServerMonitorModel(connection: connection)
      }
      startPolling(connection)
    } catch { fail(error) }
  }

  private func startPolling(_ connection: SshConnection) {
    guard polling == nil, !receivedEnd else { return }
    polling = Task { [weak self, connection] in
      while !Task.isCancelled {
        guard self != nil else {
          connection.disconnect()
          return
        }
        self?.consume(connection.pollEvents())
        self?.flushInput()
        if self?.receivedEnd == true { return }
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      }
    }
  }

  func enterBackground() {
    guard isActive else { return }
    if state != .connected {
      close()
      localErrorKey = "ssh.error.backgroundCancelled"
      return
    }
    cancelRecovery()
    isSuspended = true
    connection?.setInputSuspended(suspended: true)
    pendingInput.removeAll(keepingCapacity: false)
    polling?.cancel()
    polling = nil
    files?.setConnected(false, userInitiated: true)
    monitor?.setForeground(false)
  }

  func restoreForeground() {
    guard isSuspended, !isCheckingConnection, !receivedEnd else { return }
    guard state == .connected, let connection else {
      recoveryFailed()
      return
    }
    startPolling(connection)
    isCheckingConnection = true
    let operation = RemoteOperation()
    recoveryOperation = operation
    let revision = lifecycleRevision
    recovery = Task { [weak self, connection] in
      do {
        try await connection.checkConnection(operation: operation)
        guard !Task.isCancelled, self?.lifecycleRevision == revision,
          self?.state == .connected, self?.receivedEnd == false
        else { return }
        connection.setInputSuspended(suspended: false)
        self?.isSuspended = false
        self?.isCheckingConnection = false
        self?.recoveryOperation = nil
        self?.recovery = nil
        self?.files?.setConnected(true)
        self?.monitor?.setForeground(true)
      } catch {
        guard !Task.isCancelled, self?.lifecycleRevision == revision else { return }
        self?.recoveryFailed()
      }
    }
  }

  private func cancelRecovery() {
    lifecycleRevision += 1
    recoveryOperation?.cancel()
    recoveryOperation = nil
    recovery?.cancel()
    recovery = nil
    isCheckingConnection = false
  }

  private func recoveryFailed() {
    close()
    state = .failed
    failure = .connectionLost
    localErrorKey = "ssh.error.resumeFailed"
  }

  func consume(_ events: [SshEvent]) {
    for event in events {
      guard !receivedEnd else { return }
      switch event {
      case .stateChanged(let state):
        if self.state != .disconnecting { self.state = state }
        if state == .connected && self.state == .connected {
          files?.setConnected(true)
          monitor?.setConnected(true)
          testSucceeded = isConnectionTest
          onConnected?()
          onConnected = nil
          if isConnectionTest { disconnect() }
        }
      case .hostKey(let algorithm, let fingerprint):
        if state != .disconnecting {
          onHostKey?(
            HostKeyChallenge(id: id, target: target, algorithm: algorithm, fingerprint: fingerprint)
          )
        }
      case .output(let data):
        receivedBytes += data.count
        surface.view.feed(byteArray: Array(data)[...])
      case .ended(let reason, let error, let status):
        cancelRecovery()
        isSuspended = false
        receivedEnd = true
        endReason = reason
        failure = error
        exitStatus = status
        state = error == nil ? .disconnected : .failed
        files?.setConnected(false)
        monitor?.setConnected(false)
        pendingInput.removeAll(keepingCapacity: false)
        onHostKey = nil
        onEnded?(id)
        onEnded = nil
        onConnected = nil
      }
    }
  }

  func confirmHostKey(_ fingerprint: String, accept: Bool) {
    do { try connection?.confirmHostKey(fingerprint: fingerprint, accept: accept) } catch {
      fail(error)
      connection?.disconnect()
    }
  }

  func send(_ bytes: [UInt8]) {
    guard isConnected, !bytes.isEmpty else { return }
    guard pendingInput.count + bytes.count <= 256 * 1024 else {
      localErrorKey = "ssh.error.inputBackpressure"
      disconnect()
      return
    }
    pendingInput.append(contentsOf: bytes)
    flushInput()
  }

  private func flushInput() {
    guard isConnected, let connection else { return }
    for _ in 0..<4 {
      guard !pendingInput.isEmpty else { return }
      let chunk = pendingInput.prefix(16 * 1024)
      do {
        try connection.sendInput(bytes: Data(chunk))
        pendingInput.removeFirst(chunk.count)
      } catch SshError.Failure(let code) where code == .inputBackpressure {
        return  // Preserve every byte and retry on the next UI frame.
      } catch {
        fail(error)
        connection.disconnect()
        return
      }
    }
  }

  func resize(columns: Int, rows: Int) {
    let columns = UInt32(max(1, min(1000, columns)))
    let rows = UInt32(max(1, min(1000, rows)))
    guard self.columns != columns || self.rows != rows else { return }
    self.columns = columns
    self.rows = rows
    do { try connection?.resize(columns: columns, rows: rows) } catch {
      fail(error)
      connection?.disconnect()
    }
  }

  func disconnect() {
    guard isActive else { return }
    cancelRecovery()
    isSuspended = false
    if let connection { startPolling(connection) }
    state = .disconnecting
    files?.setConnected(false, userInitiated: true)
    monitor?.setConnected(false)
    pendingInput.removeAll(keepingCapacity: false)
    connection?.disconnect()
  }

  func close() {
    cancelRecovery()
    isSuspended = false
    files?.setConnected(false, userInitiated: true)
    monitor?.setConnected(false)
    receivedEnd = true
    connection?.disconnect()
    polling?.cancel()
    polling = nil
    connection = nil
    onHostKey = nil
    onEnded?(id)
    onEnded = nil
    onConnected = nil
    state = .disconnected
    pendingInput.removeAll(keepingCapacity: false)
  }

  private func fail(_ error: Error) {
    if case SshError.Failure(let code) = error { failure = code } else { failure = .internal }
    state = .failed
  }
}

extension FailureCode {
  var localizationKey: String {
    switch self {
    case .invalidConfiguration: "ssh.error.invalidConfiguration"
    case .connectionFailed: "ssh.error.connectionFailed"
    case .timeout: "ssh.error.timeout"
    case .hostKeyRejected: "ssh.error.hostKeyRejected"
    case .hostKeyChanged: "ssh.error.hostKeyChanged"
    case .unsupportedHostKey: "ssh.error.unsupportedHostKey"
    case .authenticationFailed: "ssh.error.authenticationFailed"
    case .invalidPrivateKey: "ssh.error.invalidPrivateKey"
    case .unsupportedPrivateKey: "ssh.error.unsupportedPrivateKey"
    case .ptyFailed: "ssh.error.ptyFailed"
    case .connectionLost: "ssh.error.connectionLost"
    case .notConnected: "ssh.error.notConnected"
    case .inputBackpressure: "ssh.error.inputBackpressure"
    case .internal: "ssh.error.internal"
    }
  }
}
