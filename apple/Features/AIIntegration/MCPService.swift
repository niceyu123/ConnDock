#if os(macOS)
  import AppKit
  import CryptoKit
  import Foundation
  import Observation
  import SSHCoreBridge

  struct MCPSource: Sendable { let pid: Int32 }

  struct MCPApproval: Identifiable {
    let id: UUID
    let target: ConnectionTarget
    let command: String
    let timeout: UInt32
    let source: MCPSource
    let expiresAt: Date
  }

  struct MCPAuditEntry: Codable, Identifiable {
    let id: UUID
    let time: Date
    let tool: MCPTool
    let hostID: UUID?
    let result: String
    let durationMilliseconds: Int
    let commandHash: String?
  }

  @MainActor
  final class MCPExecutionControl {
    let operation = RemoteOperation()
    private(set) var failure: MCPFailure?
    var connection: SshConnection?
    var checkAuthorization: (() throws -> Void)?
    func check() throws {
      if let failure { throw failure }
      try Task.checkCancellation()
      try checkAuthorization?()
    }
    func cancel(_ code: String = "CANCELLED") {
      guard failure == nil else { return }
      failure = MCPFailure(code)
      operation.cancel()
      connection?.disconnect()
    }
    func close() {
      operation.cancel()
      connection?.disconnect()
      connection = nil
    }
  }

  struct MCPInvocation {
    let request: MCPRequest
    let host: StoredHost
    let target: ConnectionTarget
    let grant: MCPHostGrant
    let library: HostLibrary
  }

  @MainActor
  protocol MCPExecuting {
    func execute(_ invocation: MCPInvocation, control: MCPExecutionControl) async throws -> MCPValue
  }

  @MainActor @Observable
  final class MCPService {
    private(set) var policy: MCPPolicy
    private(set) var approvals: [MCPApproval] = []
    private(set) var audit: [MCPAuditEntry]
    private(set) var failure: MCPFailure?
    private(set) var testResult: MCPFailure?
    private(set) var testing = false
    private(set) var locked = false
    var isEnabled: Bool { policy.enabled }
    var activeRequestCount: Int { controls.count }
    @ObservationIgnored private let library: HostLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let executor: any MCPExecuting
    @ObservationIgnored private let listens: Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var controls: [UUID: MCPExecutionControl] = [:]
    @ObservationIgnored private var decisions: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var ipc: MCPIPCServer?
    @ObservationIgnored private var approvalPresenter: MCPApprovalPresenter?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let policyKey = "mcp.policy.v1"
    private static let auditKey = "mcp.audit.v1"

    init(
      library: HostLibrary, defaults: UserDefaults = .standard,
      executor: (any MCPExecuting)? = nil, listens: Bool = true
    ) {
      self.library = library
      self.defaults = defaults
      self.executor = executor ?? MCPRemoteExecutor()
      self.listens = listens
      policy =
        defaults.data(forKey: Self.policyKey).flatMap {
          try? JSONDecoder().decode(MCPPolicy.self, from: $0)
        } ?? MCPPolicy()
      audit = Array(
        (defaults.data(forKey: Self.auditKey).flatMap {
          try? JSONDecoder().decode([MCPAuditEntry].self, from: $0)
        } ?? []).prefix(200))
      if listens {
        observeSession()
        if policy.enabled { startListener() }
      }
    }

    var helperURL: URL {
      Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp")
    }
    var socketURL: URL { MCPIPCServer.socketURL }
    var installationCommand: String {
      let quote: (String) -> String = {
        "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
      }
      return "codex mcp add conndock -- \(quote(helperURL.path)) --socket \(quote(socketURL.path))"
    }

    func configureUI(preferences: AppPreferences) {
      if approvalPresenter == nil {
        approvalPresenter = MCPApprovalPresenter(service: self, preferences: preferences)
      }
    }

    func setEnabled(_ enabled: Bool) {
      invalidate(enabled ? "AUTHORIZATION_CHANGED" : "MCP_DISABLED")
      policy.enabled = enabled
      persistPolicy()
      ipc?.stop()
      ipc = nil
      failure = nil
      if enabled && listens { startListener() }
    }
    func setGrant(_ grant: MCPHostGrant?, for id: UUID) {
      invalidate("AUTHORIZATION_CHANGED")
      policy.grants[id.uuidString] = grant
      persistPolicy()
    }
    func revokeAll() {
      invalidate("HOST_NOT_AUTHORIZED")
      policy.grants.removeAll()
      persistPolicy()
    }
    func setLocked(_ value: Bool) {
      locked = value
      if value { invalidate("APP_LOCKED") }
    }
    func shutdown() {
      invalidate("APP_UNAVAILABLE")
      ipc?.stop()
      ipc = nil
    }
    func clearAudit() {
      audit.removeAll()
      defaults.removeObject(forKey: Self.auditKey)
    }

    func resolveApproval(_ id: UUID, allow: Bool) {
      guard let decision = decisions.removeValue(forKey: id) else { return }
      approvals.removeAll { $0.id == id }
      if allow {
        decision.resume()
      } else {
        decision.resume(throwing: MCPFailure("APPROVAL_DENIED"))
      }
      approvalPresenter?.update()
    }

    private func invalidate(_ code: String) {
      generation = UUID()
      for control in controls.values { control.cancel(code) }
      let pending = decisions
      decisions.removeAll()
      approvals.removeAll()
      for decision in pending.values { decision.resume(throwing: MCPFailure(code)) }
      approvalPresenter?.update()
    }
    private func cancel(_ id: UUID, code: String) {
      controls[id]?.cancel(code)
      if let decision = decisions.removeValue(forKey: id) {
        decision.resume(throwing: MCPFailure(code))
      }
      approvals.removeAll { $0.id == id }
      approvalPresenter?.update()
    }

    private func persistPolicy() {
      defaults.set(try? JSONEncoder().encode(policy), forKey: Self.policyKey)
    }
    private func startListener() {
      do {
        let listener = MCPIPCServer()
        try listener.start { [weak self] tool, arguments, source in
          guard let self else { return .failure("APP_UNAVAILABLE") }
          return await self.handle(tool: tool, arguments: arguments, source: source)
        }
        ipc = listener
      } catch {
        failure = MCPFailure("IPC_UNAVAILABLE")
        policy.enabled = false
        persistPolicy()
      }
    }

    func handle(tool name: String, arguments: [String: MCPValue], source: MCPSource) async
      -> MCPResponse
    {
      let started = Date()
      let id = UUID()
      var request: MCPRequest?
      var result: MCPResponse
      do {
        guard policy.enabled else { throw MCPFailure("MCP_DISABLED") }
        guard !locked, !listens || NSApplication.shared.isProtectedDataAvailable else {
          throw MCPFailure("APP_LOCKED")
        }
        guard controls.count < 4 else { throw MCPFailure("BUSY") }
        let parsed = try MCPRequest.parse(tool: name, arguments: arguments)
        request = parsed
        let token = generation
        let host = try authorizedHost(parsed)
        let target = host?.target
        let revision = host?.syncRevision
        let reference = host?.credentialRef
        let jumpID = host.flatMap { library.connectionOptions(for: $0.id).jumpHostID }
        let jump = jumpID.flatMap { library.host($0) }
        let jumpRevision = jump?.syncRevision
        let jumpReference = jump?.credentialRef
        let control = MCPExecutionControl()
        controls[id] = control
        defer {
          control.close()
          controls.removeValue(forKey: id)
        }
        control.checkAuthorization = { [weak self] in
          guard let self else { throw MCPFailure("APP_UNAVAILABLE") }
          guard self.policy.enabled else { throw MCPFailure("MCP_DISABLED") }
          guard !self.locked, !self.listens || NSApplication.shared.isProtectedDataAvailable else {
            throw MCPFailure("APP_LOCKED")
          }
          guard self.generation == token else { throw MCPFailure("AUTHORIZATION_CHANGED") }
          if let host, let target {
            guard self.library.host(host.id) != nil, host.syncRevision == revision,
              host.credentialRef == reference, host.target.hasSameIdentity(as: target),
              self.policy.allows(parsed.tool, host: host)
            else { throw MCPFailure("HOST_NOT_AUTHORIZED") }
            if let jumpID {
              guard let jump, self.library.host(jumpID) != nil, jump.syncRevision == jumpRevision,
                jump.credentialRef == jumpReference, self.policy.allows(parsed.tool, host: jump)
              else { throw MCPFailure("JUMP_NOT_AUTHORIZED") }
            }
          }
        }
        let monitor = Task { [weak self] in
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .milliseconds(100))
              try control.check()
              if Date().timeIntervalSince(started) > 150 { throw MCPFailure("TIMEOUT") }
            } catch {
              if !Task.isCancelled {
                self?.cancel(id, code: (error as? MCPFailure)?.code ?? "CANCELLED")
              }
              return
            }
          }
        }
        defer { monitor.cancel() }
        result = try await withTaskCancellationHandler {
          let value = try await run(
            parsed, id: id, host: host, target: target, source: source, control: control)
          try control.check()
          return .success(value)
        } onCancel: {
          Task { @MainActor [weak self] in self?.cancel(id, code: "CANCELLED") }
        }
      } catch let error as MCPFailure { result = .failure(error.code) } catch is CancellationError {
        result = .failure("CANCELLED")
      } catch { result = .failure("REMOTE_FAILURE") }
      if let request {
        let hash = request.command.map {
          SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        audit.insert(
          MCPAuditEntry(
            id: id, time: started, tool: request.tool, hostID: request.hostID,
            result: result.error?.code ?? "OK",
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), commandHash: hash),
          at: 0)
        audit = Array(audit.prefix(200))
        defaults.set(try? JSONEncoder().encode(audit), forKey: Self.auditKey)
      }
      return result
    }

    private func authorizedHost(_ request: MCPRequest) throws -> StoredHost? {
      if request.tool == .listHosts { return nil }
      guard let id = request.hostID, let host = library.host(id),
        policy.allows(request.tool, host: host)
      else {
        throw MCPFailure("HOST_NOT_AUTHORIZED")
      }
      guard let grant = policy.grants[id.uuidString] else {
        throw MCPFailure("HOST_NOT_AUTHORIZED")
      }
      if request.tool == .sftpList {
        guard let path = request.path, MCPPathPolicy.allows(path, roots: grant.roots) else {
          throw MCPFailure("PATH_NOT_AUTHORIZED")
        }
      }
      if request.tool == .getServiceStatus {
        guard let service = request.serviceName,
          grant.services.map({ $0.hasSuffix(".service") ? $0 : $0 + ".service" }).contains(service)
        else { throw MCPFailure("SERVICE_NOT_AUTHORIZED") }
      }
      return host
    }

    private func run(
      _ request: MCPRequest, id: UUID, host: StoredHost?, target: ConnectionTarget?,
      source: MCPSource, control: MCPExecutionControl
    ) async throws -> MCPValue {
      try control.check()
      if request.tool == .listHosts {
        return .object([
          "hosts": .array(
            library.hosts.filter { policy.allows(.listHosts, host: $0) }.map {
              .object([
                "host_id": .string($0.id.uuidString), "name": .string($0.title),
                "group": $0.groupID.flatMap { id in library.groups.first { $0.id == id }?.name }
                  .map(MCPValue.string) ?? .null,
              ])
            })
        ])
      }
      guard let host, let target, let grant = policy.grants[host.id.uuidString] else {
        throw MCPFailure("HOST_NOT_AUTHORIZED")
      }
      if request.tool == .getHostInfo {
        return .object([
          "host_id": .string(host.id.uuidString), "name": .string(host.title),
          "port": .number(Double(host.port)), "authentication": .string(host.authMethodRaw),
          "credential_available": .bool(host.credentialRef != nil),
          "tools": .array(
            grant.tools.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
        ])
      }
      if request.tool == .sshExec {
        guard !listens || approvalPresenter != nil else { throw MCPFailure("UI_UNAVAILABLE") }
        let approval = MCPApproval(
          id: id, target: target, command: request.command ?? "", timeout: request.timeout,
          source: source, expiresAt: Date().addingTimeInterval(60))
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(60)) } catch { return }
          self?.cancel(id, code: "APPROVAL_TIMEOUT")
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { continuation in
          decisions[id] = continuation
          approvals.append(approval)
          approvalPresenter?.update()
        }
        try control.check()
      }
      return try await executor.execute(
        MCPInvocation(request: request, host: host, target: target, grant: grant, library: library),
        control: control)
    }

    func testConnection() {
      guard !testing else { return }
      testing = true
      testResult = nil
      Task {
        defer { testing = false }
        do {
          guard isEnabled else { throw MCPFailure("MCP_DISABLED") }
          let process = Process()
          process.executableURL = helperURL
          process.arguments = ["--socket", socketURL.path, "--check"]
          process.standardOutput = FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          try process.run()
          let deadline = Date().addingTimeInterval(8)
          while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
          }
          if process.isRunning {
            process.terminate()
            throw MCPFailure("TIMEOUT")
          }
          guard process.terminationStatus == 0 else { throw MCPFailure("IPC_UNAVAILABLE") }
          testResult = MCPFailure("TEST_OK")
        } catch { testResult = (error as? MCPFailure) ?? MCPFailure("IPC_UNAVAILABLE") }
      }
    }

    private func observeSession() {
      let center = NSWorkspace.shared.notificationCenter
      observers.append(
        center.addObserver(
          forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setLocked(true) } })
      observers.append(
        center.addObserver(
          forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setLocked(false) } })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: .NSApplicationProtectedDataWillBecomeUnavailable, object: nil,
          queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setLocked(true) } })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: .NSApplicationProtectedDataDidBecomeAvailable, object: nil,
          queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setLocked(false) } })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.shutdown() } })
      locked = !NSApplication.shared.isProtectedDataAvailable
    }
  }
#endif
