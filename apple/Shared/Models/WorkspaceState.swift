import Foundation
import Observation
import SSHCoreBridge

public struct WorkspaceTab: Identifiable, Equatable {
  public let id: UUID
  public let ordinal: Int
  public var title: String?
  public var isLocal: Bool
  public var isWelcome: Bool { ordinal == 0 && title == nil && !isLocal }

  public init(id: UUID, ordinal: Int, title: String? = nil, isLocal: Bool = false) {
    self.id = id
    self.ordinal = ordinal
    self.title = title
    self.isLocal = isLocal
  }
}

enum WorkspaceTool: String, Identifiable {
  case files, monitor
  var id: String { rawValue }
}

@MainActor @Observable
public final class WorkspaceState {
  let commandLibrary = CommandLibrary()
  public private(set) var tabs: [WorkspaceTab]
  public var selection: UUID
  public var showNewHost = false
  public var searchFocused = false
  public var search = ""
  var selectedHostID: UUID?
  var selectedGroupID: UUID?
  var editingHostID: UUID?
  var editingGroupID: UUID?
  var showGroupEditor = false
  var requireCredentialInput = false
  var editorTestOnly = false
  var operationErrorKey: String?
  var presentedTool: WorkspaceTool?
  private(set) var openingHostID: UUID?
  private(set) var library: HostLibrary?
  private(set) var libraryErrorKey: String?
  private(set) var cloudSync: CloudSyncService?
  #if os(macOS)
    private(set) var mcp: MCPService?
    public func configureMCP(preferences: AppPreferences) {
      mcp?.configureUI(preferences: preferences)
    }
  #endif
  var storageStatusKey: String {
    cloudSync?.isEnabled == true ? "cloud.storageEnabled" : "hosts.deviceOnly"
  }
  private(set) var trustPrompt: HostKeyChallenge?
  private(set) var isBackgrounded = false
  private var applicationRevision = 0
  public func setApplicationBackgrounded(_ backgrounded: Bool) {
    guard isBackgrounded != backgrounded else { return }
    applicationRevision &+= 1
    isBackgrounded = backgrounded
    for session in sessions.values {
      if backgrounded { session.enterBackground() } else { session.restoreForeground() }
    }
  }
  public func setApplicationActive(_ active: Bool) {
    cloudSync?.setForeground(active)
    if active { cloudSync?.resume() }
  }
  private var queuedTrust: [HostKeyChallenge] = []
  var reconnectTarget: ConnectionTarget?
  private(set) var connectionRevision = 0
  private var sessions: [UUID: TerminalSession] = [:]
  #if os(macOS)
    private var localShells: [UUID: LocalShellSession] = [:]
    var selectedLocalShell: LocalShellSession? { localShells[selection] }
  #endif
  @ObservationIgnored private let trustStore: HostTrustStore
  @ObservationIgnored private var nextOrdinal = 1

  public init(trustDefaults: UserDefaults? = nil) {
    let isolated =
      ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] == "1"
      ? UserDefaults(suiteName: "ConnDock.UITesting") : nil
    trustStore = HostTrustStore(defaults: trustDefaults ?? isolated ?? .standard)
    let tab = WorkspaceTab(id: UUID(), ordinal: 0)
    tabs = [tab]
    selection = tab.id
    loadLibrary()
  }

  init(library: HostLibrary, trustDefaults: UserDefaults) {
    trustStore = HostTrustStore(defaults: trustDefaults)
    self.library = library
    cloudSync = CloudSyncService(library: library)
    #if os(macOS)
      mcp = MCPService(
        library: library, defaults: trustDefaults,
        executor: MCPRemoteExecutor(trustStore: trustStore), listens: false)
    #endif
    let tab = WorkspaceTab(id: UUID(), ordinal: 0)
    tabs = [tab]
    selection = tab.id
  }

  func loadLibrary() {
    do {
      if ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] == "1" {
        let directory = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true
        ).appendingPathComponent("ConnDock/UITesting", isDirectory: true)
        if ProcessInfo.processInfo.environment["CONNDOCK_RESET_PREFERENCES"] == "1",
          FileManager.default.fileExists(atPath: directory.path)
        {
          try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: "ConnDock.UITesting") else {
          throw HostLibraryError.unavailable
        }
        library = try HostLibrary(
          storeURL: directory.appendingPathComponent("Hosts.store"),
          vault: KeychainCredentialStorage(service: "ConnDock.UITesting.Credentials.v1"),
          cleanupDefaults: defaults)
      } else {
        library = try HostLibrary()
      }
      libraryErrorKey = nil
      if let library {
        cloudSync = CloudSyncService(library: library)
        #if os(macOS)
          let isolated =
            ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] == "1"
            ? UserDefaults(suiteName: "ConnDock.UITesting") : nil
          mcp = MCPService(
            library: library, defaults: isolated ?? .standard,
            executor: MCPRemoteExecutor(trustStore: trustStore))
        #endif
      }
    } catch { libraryErrorKey = "storage.error.unavailable" }
  }

  public func addTerminal() {
    let tab = WorkspaceTab(id: UUID(), ordinal: nextOrdinal)
    nextOrdinal += 1
    tabs.append(tab)
    selection = tab.id
  }

  public var selectedTab: WorkspaceTab? {
    tabs.first(where: { $0.id == selection })
  }

  public func openLocalTerminal() {
    #if os(macOS)
      if let existing = tabs.first(where: { $0.isLocal }) {
        selection = existing.id
        return
      }
      let tab = WorkspaceTab(id: UUID(), ordinal: nextOrdinal, isLocal: true)
      nextOrdinal += 1
      localShells[tab.id] = LocalShellSession()
      tabs.append(tab)
      selection = tab.id
    #endif
  }

  public func closeTab(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    sessions.removeValue(forKey: id)?.close()
    #if os(macOS)
      localShells.removeValue(forKey: id)?.close()
    #endif
    tabs.remove(at: index)
    if tabs.isEmpty {
      let welcome = WorkspaceTab(id: UUID(), ordinal: 0)
      tabs = [welcome]
      selection = welcome.id
    } else if selection == id {
      selection = tabs[min(index, tabs.count - 1)].id
    }
  }

  var selectedSession: TerminalSession? { sessions[selection] }

  func connect(
    target: ConnectionTarget, authentication: AuthenticationRequest,
    sourceHostID: UUID? = nil, testOnly: Bool = false
  ) {
    guard !isBackgrounded else {
      operationErrorKey = "ssh.error.backgroundCancelled"
      return
    }
    if selectedTab?.isLocal == true { addTerminal() }
    if let current = sessions[selection] {
      if current.isActive { addTerminal() } else { current.close() }
    }
    let id = selection
    if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].title = target.title }
    let session = TerminalSession(
      id: UUID(), target: target, sourceHostID: sourceHostID, isConnectionTest: testOnly)
    sessions[id] = session
    session.onHostKey = { [weak self] challenge in self?.enqueueTrust(challenge) }
    session.onEnded = { [weak self] id in self?.removeTrustPrompt(for: id) }
    if let sourceHostID, !testOnly {
      session.onConnected = { [weak self] in
        do { try self?.library?.markConnected(sourceHostID) } catch {
          self?.operationErrorKey = "storage.error.unavailable"
        }
      }
    }
    do {
      let fingerprint = try trustStore.fingerprint(host: target.host, port: target.port)
      session.connect(authentication: authentication, trustedFingerprint: fingerprint)
    } catch {
      session.localErrorKey = "ssh.error.trustStore"
      session.close()
    }
    connectionRevision += 1
  }

  func enqueueTrust(_ challenge: HostKeyChallenge) {
    if trustPrompt == nil { trustPrompt = challenge } else { queuedTrust.append(challenge) }
  }

  @discardableResult
  func resolveTrust(challenge: HostKeyChallenge, accept: Bool) -> Bool {
    guard let current = trustPrompt, current.id == challenge.id,
      current.fingerprint == challenge.fingerprint, current.algorithm == challenge.algorithm
    else { return false }
    trustPrompt = queuedTrust.isEmpty ? nil : queuedTrust.removeFirst()
    guard let session = sessions.values.first(where: { $0.id == challenge.id }) else {
      return false
    }
    if accept {
      do {
        try trustStore.remember(
          host: challenge.target.host, port: challenge.target.port,
          algorithm: challenge.algorithm, fingerprint: challenge.fingerprint)
      } catch {
        session.localErrorKey = "ssh.error.trustStore"
        session.confirmHostKey(challenge.fingerprint, accept: false)
        return false
      }
    }
    session.confirmHostKey(challenge.fingerprint, accept: accept)
    return true
  }

  func requestConnect() {
    if let selectedHostID {
      Task { await connectSavedHost(selectedHostID) }
    } else {
      requestReconnect()
    }
  }

  func requestReconnect() {
    if let selectedHostID, selectedSession == nil {
      Task { await connectSavedHost(selectedHostID) }
      return
    }
    if let session = selectedSession, let hostID = session.sourceHostID,
      let host = library?.host(hostID), host.target.hasSameIdentity(as: session.target)
    {
      Task { await connectSavedHost(hostID, testOnly: session.isConnectionTest) }
      return
    }
    editingHostID = nil
    reconnectTarget = selectedSession?.target
    showNewHost = true
  }

  func disconnectSelected() {
    if let id = selectedSession?.id { removeTrustPrompt(for: id) }
    selectedSession?.disconnect()
  }

  private func removeTrustPrompt(for id: UUID) {
    queuedTrust.removeAll { $0.id == id }
    if trustPrompt?.id == id { trustPrompt = queuedTrust.isEmpty ? nil : queuedTrust.removeFirst() }
  }

  func session(for tab: UUID) -> TerminalSession? { sessions[tab] }

  func isConnected(_ host: StoredHost) -> Bool {
    sessions.values.contains {
      $0.sourceHostID == host.id && $0.target.hasSameIdentity(as: host.target) && $0.isConnected
    }
  }

  func requestEditHost(_ id: UUID, requireCredential: Bool = false, testOnly: Bool = false) {
    editingHostID = id
    reconnectTarget = nil
    requireCredentialInput = requireCredential
    editorTestOnly = testOnly
    showNewHost = true
  }

  func finishHostEditing() {
    editingHostID = nil
    reconnectTarget = nil
    requireCredentialInput = false
    editorTestOnly = false
  }

  func connectSavedHost(_ id: UUID, newTab: Bool = false, testOnly: Bool = false) async {
    guard openingHostID == nil, !isBackgrounded else { return }
    guard let library, let host = library.host(id) else {
      operationErrorKey = "storage.error.notFound"
      return
    }
    let target = host.target
    if !newTab && !testOnly,
      let active = sessions.first(where: {
        $0.value.sourceHostID == id && $0.value.target.hasSameIdentity(as: target)
          && $0.value.isActive && !$0.value.isConnectionTest
      })
    {
      selection = active.key
      connectionRevision += 1
      return
    }
    openingHostID = id
    let revision = applicationRevision
    let originatingTab = selection
    defer { openingHostID = nil }
    do {
      let credential = try await library.credential(for: host)
      guard selection == originatingTab, tabs.contains(where: { $0.id == originatingTab }) else {
        return
      }
      guard revision == applicationRevision, !isBackgrounded else {
        operationErrorKey = "ssh.error.backgroundCancelled"
        return
      }
      guard let credential else {
        requestEditHost(id, requireCredential: true, testOnly: testOnly)
        return
      }
      guard !isBackgrounded, library.host(id)?.target.hasSameIdentity(as: target) == true else {
        throw HostLibraryError.conflict
      }
      if newTab { addTerminal() }
      selectedHostID = id
      connect(
        target: target, authentication: credential.request, sourceHostID: id, testOnly: testOnly)
    } catch {
      guard selection == originatingTab, tabs.contains(where: { $0.id == originatingTab }) else {
        return
      }
      guard revision == applicationRevision, !isBackgrounded else {
        operationErrorKey = "ssh.error.backgroundCancelled"
        return
      }
      operationErrorKey =
        (error as? HostLibraryError)?.localizationKey ?? "storage.error.credential"
    }
  }

  func requestGroupEditor(_ id: UUID? = nil) {
    editingGroupID = id
    showGroupEditor = true
  }
}
