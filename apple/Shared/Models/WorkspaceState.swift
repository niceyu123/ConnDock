import Foundation
import Observation
import SSHCoreBridge

#if os(macOS)
  import AppKit
#endif

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
  private(set) var terminalSplits: [TerminalSplit] = []
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
  var connectionLifecycleRevision: Int { applicationRevision }
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
  var reconnectOptions: HostConnectionOptions?
  private(set) var connectionRevision = 0
  private var sessions: [UUID: TerminalSession] = [:]
  private var ownedSessions: [TerminalSession] {
    sessions.values.flatMap { session in [session] + (session.jumpSession.map { [$0] } ?? []) }
  }
  private var authenticationOrder: [UUID] = []
  var authenticationPrompt: InteractiveChallenge? {
    authenticationOrder.compactMap { id in
      ownedSessions.first(where: { $0.id == id })?.authenticationChallenge
    }.first
  }
  func answerAuthentication(_ prompt: InteractiveChallenge, responses: [String]?) {
    guard let session = ownedSessions.first(where: { $0.id == prompt.sessionID }) else { return }
    session.respondAuthentication(prompt, responses: responses)
  }
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

  var selectedSplit: TerminalSplit? { terminalSplits.first { $0.contains(selection) } }

  var visibleTerminalTabs: [WorkspaceTab] {
    let ids = selectedSplit.map { [$0.first, $0.second] } ?? [selection]
    return ids.compactMap { id in tabs.first { $0.id == id } }
  }

  func splitSelected(axis: TerminalSplitAxis) {
    if let index = terminalSplits.firstIndex(where: { $0.contains(selection) }) {
      terminalSplits[index].axis = axis
      return
    }
    let first = selection
    guard tabs.contains(where: { $0.id == first }) else { return }
    addTerminal()
    terminalSplits.append(TerminalSplit(first: first, second: selection, axis: axis))
  }

  func splitSelected(with tabID: UUID, axis: TerminalSplitAxis) {
    guard tabID != selection, tabs.contains(where: { $0.id == tabID }),
      tabs.contains(where: { $0.id == selection })
    else { return }
    terminalSplits.removeAll { $0.contains(selection) || $0.contains(tabID) }
    terminalSplits.append(TerminalSplit(first: selection, second: tabID, axis: axis))
  }

  func joinSelectedSplit() { terminalSplits.removeAll { $0.contains(selection) } }

  func focusTerminal(_ id: UUID) {
    // Native focus notifications can arrive after a tab was detached or closed.
    guard visibleTerminalTabs.contains(where: { $0.id == id }) else { return }
    selection = id
  }

  func activateTerminal(_ id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selection = id
    #if os(macOS)
      let view: NSView? = localShells[id]?.view ?? sessions[id]?.surface.view
      if let view {
        let restore: () -> Void = { [weak self, weak view] in
          guard let self, let view, self.selection == id,
            self.tabs.contains(where: { $0.id == id }),
            !self.showNewHost, !self.showGroupEditor, self.trustPrompt == nil,
            self.authenticationPrompt == nil,
            self.localShells[id]?.view === view || self.sessions[id]?.surface.view === view
          else { return }
          view.window?.makeFirstResponder(view)
        }
        // SwiftUI may reparent a native surface after its layout task runs.
        // Keep the guarded request until the actual window attachment occurs.
        (view as? FocusedTerminalView)?.onWindowAttachment = restore
        (view as? FocusedLocalTerminalView)?.onWindowAttachment = restore
        restore()
      } else if sessions[id] == nil && localShells[id] == nil {
        NSApp.keyWindow?.makeFirstResponder(nil)
      }
    #else
      _ = sessions[id]?.surface.view.becomeFirstResponder()
    #endif
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
      localShells[tab.id]?.onFocus = { [weak self] in self?.focusTerminal(tab.id) }
      tabs.append(tab)
      selection = tab.id
    #endif
  }

  public func closeTab(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let companion = terminalSplits.first(where: { $0.contains(id) })?.companion(of: id)
    terminalSplits.removeAll { $0.contains(id) }
    if let sessionID = sessions[id]?.id { removeTrustPrompt(for: sessionID) }
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
      selection = companion ?? tabs[min(index, tabs.count - 1)].id
    }
  }

  var selectedSession: TerminalSession? { sessions[selection] }
  #if os(macOS)
    func localShell(for tabID: UUID) -> LocalShellSession? { localShells[tabID] }
  #endif

  func connect(
    target: ConnectionTarget, authentication: AuthenticationRequest,
    sourceHostID: UUID? = nil, testOnly: Bool = false,
    options: HostConnectionOptions = HostConnectionOptions(), jump: TerminalSession? = nil
  ) {
    guard !isBackgrounded else {
      jump?.close()
      operationErrorKey = "ssh.error.backgroundCancelled"
      return
    }
    guard options.jumpHostID == nil || jump != nil else {
      operationErrorKey = "ssh.error.jumpFailed"
      return
    }
    if selectedTab?.isLocal == true { addTerminal() }
    if let current = sessions[selection] {
      if current.isActive { addTerminal() } else { current.close() }
    }
    let id = selection
    if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].title = target.title }
    let session = TerminalSession(
      id: UUID(), target: target, sourceHostID: sourceHostID, isConnectionTest: testOnly,
      connectionOptions: options)
    sessions[id] = session
    session.onFocus = { [weak self] in self?.focusTerminal(id) }
    session.onAuthentication = { [weak self] id in self?.queueAuthentication(id) }
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
      session.connect(authentication: authentication, trustedFingerprint: fingerprint, jump: jump)
    } catch {
      jump?.close()
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
    guard let session = ownedSessions.first(where: { $0.id == challenge.id }) else {
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
    reconnectOptions = selectedSession?.connectionOptions
    showNewHost = true
  }

  func disconnectSelected() {
    if let id = selectedSession?.id { removeTrustPrompt(for: id) }
    selectedSession?.disconnect()
  }

  private func removeTrustPrompt(for id: UUID) {
    authenticationOrder.removeAll { $0 == id }
    queuedTrust.removeAll { $0.id == id }
    if trustPrompt?.id == id { trustPrompt = queuedTrust.isEmpty ? nil : queuedTrust.removeFirst() }
  }
  private func queueAuthentication(_ id: UUID) {
    if !authenticationOrder.contains(id) { authenticationOrder.append(id) }
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
    reconnectOptions = nil
    requireCredentialInput = requireCredential
    editorTestOnly = testOnly
    showNewHost = true
  }

  func finishHostEditing() {
    editingHostID = nil
    reconnectTarget = nil
    reconnectOptions = nil
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
    let hostRevision = host.syncRevision
    let options = library.connectionOptions(for: id)
    if !newTab && !testOnly,
      let active = sessions.first(where: {
        $0.value.sourceHostID == id && $0.value.target.hasSameIdentity(as: target)
          && $0.value.isActive && !$0.value.isConnectionTest
          && $0.value.connectionOptions == options
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
      let authentication = try await library.authentication(for: host)
      guard selection == originatingTab, tabs.contains(where: { $0.id == originatingTab }) else {
        return
      }
      guard revision == applicationRevision, !isBackgrounded else {
        operationErrorKey = "ssh.error.backgroundCancelled"
        return
      }
      guard let authentication else {
        requestEditHost(id, requireCredential: true, testOnly: testOnly)
        return
      }
      guard !isBackgrounded, library.host(id)?.target.hasSameIdentity(as: target) == true,
        library.host(id)?.syncRevision == hostRevision
      else {
        throw HostLibraryError.conflict
      }
      try await connectPrepared(
        target: target, authentication: authentication, sourceHostID: id,
        testOnly: testOnly, options: options, newTab: newTab)
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

  func connectPrepared(
    target: ConnectionTarget, authentication: AuthenticationRequest,
    sourceHostID: UUID?, testOnly: Bool, options: HostConnectionOptions, newTab: Bool = false,
    agentDirectory: URL? = nil
  ) async throws {
    let origin = selection
    let revision = applicationRevision
    let hostRevision = sourceHostID.flatMap { library?.host($0)?.syncRevision }
    var jumpSession: TerminalSession?
    let agentAccess: AgentSocketAccess?
    if case .agent(let socket, _) = authentication {
      if let agentDirectory {
        agentAccess = try AgentSocketAccess(directory: agentDirectory, socketPath: socket)
      } else if let sourceHostID {
        agentAccess = try library?.agentAccess(for: sourceHostID, socketPath: socket)
      } else {
        throw HostLibraryError.credential
      }
    } else {
      agentAccess = nil
    }
    if let jumpID = options.jumpHostID {
      guard let library, let host = library.host(jumpID), jumpID != sourceHostID,
        library.connectionOptions(for: jumpID).jumpHostID == nil
      else { throw HostLibraryError.invalidHost }
      let jumpTarget = host.target
      let jumpRevision = host.syncRevision
      guard let auth = try await library.authentication(for: host) else {
        throw HostLibraryError.jumpCredential
      }
      guard selection == origin, tabs.contains(where: { $0.id == origin }), !isBackgrounded,
        revision == applicationRevision, library.host(jumpID)?.syncRevision == jumpRevision,
        library.host(jumpID)?.target.hasSameIdentity(as: jumpTarget) == true
      else { throw HostLibraryError.conflict }
      var jumpOptions = library.connectionOptions(for: jumpID)
      jumpOptions.filesOnly = true
      let parent = TerminalSession(id: UUID(), target: jumpTarget, connectionOptions: jumpOptions)
      if case .agent(let socket, _) = auth {
        parent.agentAccess = try library.agentAccess(for: jumpID, socketPath: socket)
      }
      parent.onHostKey = { [weak self] in self?.enqueueTrust($0) }
      parent.onAuthentication = { [weak self] id in self?.queueAuthentication(id) }
      parent.onEnded = { [weak self] in self?.removeTrustPrompt(for: $0) }
      let fingerprint = try trustStore.fingerprint(host: jumpTarget.host, port: jumpTarget.port)
      parent.connect(authentication: auth, trustedFingerprint: fingerprint)
      jumpSession = parent
    }
    guard selection == origin, tabs.contains(where: { $0.id == origin }),
      revision == applicationRevision,
      !isBackgrounded
    else {
      jumpSession?.close()
      throw HostLibraryError.conflict
    }
    if let sourceHostID {
      guard library?.host(sourceHostID)?.syncRevision == hostRevision,
        library?.host(sourceHostID)?.target.hasSameIdentity(as: target) == true
      else {
        jumpSession?.close()
        throw HostLibraryError.conflict
      }
    }
    if newTab { addTerminal() }
    selectedHostID = sourceHostID
    connect(
      target: target, authentication: authentication, sourceHostID: sourceHostID,
      testOnly: testOnly,
      options: options, jump: jumpSession)
    if selectedSession?.isActive == true { selectedSession?.agentAccess = agentAccess }
  }

  func requestGroupEditor(_ id: UUID? = nil) {
    editingGroupID = id
    showGroupEditor = true
  }
}
