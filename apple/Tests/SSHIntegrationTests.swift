import SSHCoreBridge
import SwiftTerm
import SwiftUI
import XCTest

@testable import ConnDockKit

/// Opt-in, real SSH → UniFFI → SwiftTerm tests. The temporary configuration is
/// copied into the test host's Documents directory, never bundled or committed.
@MainActor
final class SSHIntegrationTests: XCTestCase {
  struct Configuration: Decodable {
    let host: String
    let port: UInt16
    let username: String
    let fingerprint: String
    let privateKey: String?
    let password: String?
    let passphrase: String?
    let captureScreenshots: Bool
    let workingDirectory: String?
    let runIdentifier: UUID
    let expectLinux: Bool?
    let isolatedFixture: Bool?
    let runCodex: Bool?
    let agentSocket: String?
    let agentFingerprint: String?
    let targetPort: UInt16?
  }

  func testAdvancedTransportThroughBridge() async throws {
    let configuration = try takeConfiguration()
    let key = try XCTUnwrap(configuration.privateKey)
    let auth = AuthenticationRequest.ed25519(privateKey: key, passphrase: configuration.passphrase)
    let request = ConnectionRequest(
      host: configuration.host, port: configuration.port, username: configuration.username,
      trustedFingerprint: configuration.fingerprint, columns: 80, rows: 24, timeoutSeconds: 10)
    let parent = try connectAdvanced(
      request: request, authentication: auth, transportOnly: true, allowInteractive: false,
      jump: nil)
    defer { parent.disconnect() }
    func connected(_ connection: SshConnection, stage: String) async throws {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        for event in connection.pollEvents() {
          if case .stateChanged(let state) = event, state == .connected { return }
          if case .ended(_, let failure, _) = event {
            XCTFail("Advanced transport failed at \(stage): \(String(describing: failure))")
            throw IntegrationError.invalidConfiguration
          }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail("Advanced transport timed out")
      throw IntegrationError.invalidConfiguration
    }
    try await connected(parent, stage: "parent")
    let files = try await parent.openFiles()
    defer { files.close() }
    let output = try await parent.executeCommand(
      command: "printf apple-transport", timeoutSeconds: 5, operation: RemoteOperation())
    XCTAssertEqual(output.stdout, Data("apple-transport".utf8))
    let target = ConnectionRequest(
      host: "127.0.0.1", port: configuration.targetPort ?? 22, username: configuration.username,
      trustedFingerprint: configuration.fingerprint, columns: 80, rows: 24, timeoutSeconds: 10)
    let child = try connectAdvanced(
      request: target, authentication: auth, transportOnly: true, allowInteractive: false,
      jump: parent)
    defer { child.disconnect() }
    try await connected(child, stage: "jump target")
    let jumped = try await child.executeCommand(
      command: "printf apple-jump", timeoutSeconds: 5, operation: RemoteOperation())
    XCTAssertEqual(jumped.stdout, Data("apple-jump".utf8))
  }

  func takeConfiguration() throws -> Configuration {
    let documents = try XCTUnwrap(
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    let url = documents.appendingPathComponent("ConnDockIntegration.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("Real SSH configuration not installed; see docs/PHASE1-TESTING.md")
    }
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    // One-shot input: simulator installs can migrate Documents to another UUID.
    // Consume the temporary secret before any network or assertion can fail.
    try FileManager.default.removeItem(at: url)
    return configuration
  }

  func testRealSSHThroughNativeTerminal() async throws {
    let configuration = try takeConfiguration()
    let domain = "ConnDock.Integration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = .dark
    let workspace = WorkspaceState(trustDefaults: defaults)
    #if os(macOS)
      let root = WorkspaceRoot().environment(preferences).environment(workspace)
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1360, height: 820),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "ConnDock"
      window.contentView = NSHostingView(rootView: root)
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
    #else
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = scene.coordinateSpace.bounds
      let root = WorkspaceRoot().environment(preferences).environment(workspace)
      window.rootViewController = UIHostingController(rootView: root)
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
    #endif
    let authentication: AuthenticationRequest
    if let key = configuration.privateKey, configuration.password == nil {
      authentication = .ed25519(privateKey: key, passphrase: configuration.passphrase)
    } else if let password = configuration.password, configuration.privateKey == nil {
      authentication = .password(password: password)
    } else {
      throw IntegrationError.invalidConfiguration
    }
    let target = ConnectionTarget(
      displayName: "OpenSSH", host: configuration.host, port: configuration.port,
      username: configuration.username, usesPrivateKey: configuration.privateKey != nil)
    try await Task.sleep(for: .milliseconds(100))
    workspace.connect(
      target: target,
      authentication: authentication)
    let session = try XCTUnwrap(workspace.selectedSession)
    defer { session.close() }
    try await waitUntil { workspace.trustPrompt != nil || !session.isActive }
    let challenge = try XCTUnwrap(workspace.trustPrompt)
    XCTAssertEqual(
      challenge.fingerprint, configuration.fingerprint,
      "Verify against the directly generated test host key")
    guard challenge.fingerprint == configuration.fingerprint else {
      workspace.resolveTrust(challenge: challenge, accept: false)
      throw IntegrationError.hostKeyMismatch
    }
    workspace.resolveTrust(challenge: challenge, accept: true)
    try await waitUntil { session.isConnected || !session.isActive }
    XCTAssertTrue(session.isConnected, "SSH session must authenticate and establish a real PTY")
    let view = session.surface.view
    #if os(macOS)
      let content = try XCTUnwrap(window.contentView)
      try await waitUntil { self.attached(view, beneath: content) }
    #else
      try await waitUntil { self.attached(view, beneath: window) }
    #endif
    view.send(txt: "stty -echo; printf '\\n__READY__\\n'\n")
    try await waitUntil { self.text(view).contains("\n__READY__\n") }
    if let directory = configuration.workingDirectory {
      let escaped = directory.replacingOccurrences(of: "'", with: "'\\''")
      view.send(txt: "cd '\(escaped)'\n")
    }
    view.send(
      txt:
        "printf '\\033[31mConnDock 中文🙂\\033[0m\\n'; pwd; ls -la | head -n 12; printf '\\n__OUTPUT_DONE__\\n'\n"
    )
    try await waitUntil { self.text(view).contains("\n__OUTPUT_DONE__\n") }
    XCTAssertTrue(
      text(view).contains("ConnDock 中文🙂"), "UTF-8 must survive Rust, UniFFI and SwiftTerm")
    let terminal = view.getTerminal()
    XCTAssertTrue(
      (0..<bufferLineCount(terminal)).contains { row in
        (0..<terminal.cols).contains { col in
          terminal.getScrollInvariantLine(row: row)?[col].attribute.fg == .ansi256(code: 1)
        }
      }, "ANSI red must be rendered as a colored SwiftTerm cell")
    XCTAssertGreaterThan(session.receivedBytes, 0)
    let originalColumns = session.columns
    #if os(macOS)
      let originalWindowSize = try XCTUnwrap(window.contentView).frame.size
      window.setContentSize(
        NSSize(width: originalWindowSize.width - 100, height: originalWindowSize.height - 60))
      window.contentView?.layoutSubtreeIfNeeded()
    #else
      let originalWindowFrame = window.frame
      window.frame = originalWindowFrame.insetBy(dx: 18, dy: 18)
      window.layoutIfNeeded()
    #endif
    try await waitUntil {
      session.columns != originalColumns && session.columns == UInt32(view.getTerminal().cols)
    }
    try await Task.sleep(for: .milliseconds(100))
    let resizedColumns = session.columns
    let resizedRows = session.rows
    view.send(txt: "printf '__SIZE__'; stty size\n")
    let sizePattern = try NSRegularExpression(pattern: #"__SIZE__(\d+) (\d+)"#)
    func remoteSize() -> (String, String)? {
      let output = text(view)
      guard
        let match = sizePattern.firstMatch(
          in: output, range: NSRange(output.startIndex..., in: output)),
        let rows = Range(match.range(at: 1), in: output),
        let columns = Range(match.range(at: 2), in: output)
      else { return nil }
      return (String(output[rows]), String(output[columns]))
    }
    try await waitUntil { remoteSize() != nil }
    let reportedSize = try XCTUnwrap(remoteSize())
    XCTAssertEqual(
      reportedSize.0, String(resizedRows), "Remote PTY rows must match the resized native view")
    XCTAssertEqual(
      reportedSize.1, String(resizedColumns),
      "Remote PTY columns must match the resized native view")
    view.send(txt: "sleep 10\n")
    try await Task.sleep(for: .milliseconds(100))
    #if os(iOS)
      XCTAssertNil(view.inputAccessoryView)
      view.controlModifier = true
      view.insertText("c")
      XCTAssertFalse(view.controlModifier)
    #else
      view.send([3])
    #endif
    view.send(txt: "printf '\\n__INTERRUPTED__\\n'\n")
    try await waitUntil { self.text(view).contains("\n__INTERRUPTED__\n") }
    // Restore the native view's size before recording its real on-screen UI.
    #if os(macOS)
      window.setContentSize(originalWindowSize)
      window.contentView?.needsLayout = true
      window.contentView?.layoutSubtreeIfNeeded()
    #else
      window.frame = originalWindowFrame
      window.layoutIfNeeded()
    #endif
    try await Task.sleep(for: .milliseconds(200))
    if configuration.captureScreenshots { capture(window, variant: "zh-dark") }
    preferences.language = .english
    preferences.appearance = .light
    try await waitUntil { self.hasLightBackground(view) }
    XCTAssertTrue(session.isConnected, "Language and appearance changes must preserve SSH")
    view.send(txt: "printf '\\n__LIVE_AFTER_SETTINGS__\\n'\n")
    try await waitUntil { self.text(view).contains("\n__LIVE_AFTER_SETTINGS__\n") }
    try await Task.sleep(for: .milliseconds(200))
    if configuration.captureScreenshots { capture(window, variant: "en-light") }
    session.disconnect()
    try await waitUntil { !session.isActive }
    XCTAssertEqual(session.state, .disconnected)
    XCTAssertEqual(session.endReason, .user)
    let ordinal = workspace.tabs.count
    workspace.closeTab(workspace.selection)
    XCTAssertLessThanOrEqual(workspace.tabs.count, ordinal)
  }

  func testSavedHostsUseKeychainAndSwitchLiveSessions() async throws {
    let configuration = try takeConfiguration()
    let domain = "ConnDock.SavedIntegration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // SwiftData may retain SQLite handles after this async scope returns.
    // Leave this nonsecret, per-run database to the OS temporary-directory
    // cleanup; never unlink a store while its container still has it open.
    let vault = KeychainCredentialStorage(service: domain)
    let storeURL = directory.appendingPathComponent("Hosts.store")
    let store = try HostLibrary(storeURL: storeURL, vault: vault, cleanupDefaults: defaults)
    let credential: SavedCredential
    if let key = configuration.privateKey, configuration.password == nil {
      credential = .ed25519(privateKey: key, passphrase: configuration.passphrase)
    } else if let password = configuration.password, configuration.privateKey == nil {
      credential = .password(password)
    } else {
      throw IntegrationError.invalidConfiguration
    }
    var hostIDs: [UUID] = []
    var references: [String] = []
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = .dark
    let workspace = WorkspaceState(library: store, trustDefaults: defaults)
    #if os(macOS)
      let root = WorkspaceRoot().environment(preferences).environment(workspace)
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1360, height: 820),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "ConnDock"
      window.contentView = NSHostingView(rootView: root)
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
    #else
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = scene.coordinateSpace.bounds
      window.rootViewController = UIHostingController(
        rootView: WorkspaceRoot().environment(preferences).environment(workspace))
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
    #endif
    do {
      let group = try store.createGroup(name: "OpenSSH Validation")
      for name in ["Local OpenSSH · A", "Local OpenSSH · B"] {
        var draft = HostDraft(
          displayName: name, hostname: configuration.host, port: configuration.port,
          username: configuration.username, authMethod: credential.authMethod)
        draft.groupID = group.id
        draft.favorite = true
        let saved = try await store.saveHost(
          draft, credential: credential, rememberCredential: true)
        hostIDs.append(saved.id)
        references.append(try XCTUnwrap(saved.credentialRef))
      }
      let reopened = try HostLibrary(
        storeURL: storeURL, vault: vault, cleanupDefaults: defaults)
      XCTAssertEqual(Set(reopened.hosts.map(\.id)), Set(hostIDs))
      XCTAssertEqual(reopened.groups.first?.id, group.id)
      XCTAssertEqual(reopened.matching(favoritesOnly: true).count, 2)
      let restored = try XCTUnwrap(reopened.host(hostIDs[0]))
      let restoredCredential = try await reopened.credential(for: restored)
      XCTAssertTrue(restoredCredential == credential, "Keychain must restore the saved credential")

      await workspace.connectSavedHost(hostIDs[0])
      let firstTab = workspace.selection
      let first = try XCTUnwrap(workspace.selectedSession)
      try await waitUntil { workspace.trustPrompt != nil || !first.isActive }
      let challenge = try XCTUnwrap(workspace.trustPrompt)
      guard challenge.fingerprint == configuration.fingerprint else {
        workspace.resolveTrust(challenge: challenge, accept: false)
        throw IntegrationError.hostKeyMismatch
      }
      workspace.resolveTrust(challenge: challenge, accept: true)
      try await waitUntil { first.isConnected || !first.isActive }
      XCTAssertTrue(first.isConnected)
      await workspace.connectSavedHost(hostIDs[1], newTab: true)
      let secondTab = workspace.selection
      let second = try XCTUnwrap(workspace.selectedSession)
      try await waitUntil { second.isConnected || !second.isActive }
      XCTAssertTrue(second.isConnected)
      XCTAssertNil(workspace.trustPrompt, "The pinned endpoint must not request first trust again")
      XCTAssertNotEqual(first.id, second.id)
      XCTAssertTrue(first.surface.view !== second.surface.view)
      XCTAssertEqual(workspace.tabs.count, 2)
      XCTAssertEqual(store.matching(recentOnly: true).count, 2)

      for (tab, session, marker) in [
        (firstTab, first, "__SESSION_A__"), (secondTab, second, "__SESSION_B__"),
      ] {
        workspace.selection = tab
        let view = session.surface.view
        #if os(macOS)
          let root = try XCTUnwrap(window.contentView)
          try await waitUntil { self.attached(view, beneath: root) }
        #else
          try await waitUntil { self.attached(view, beneath: window) }
        #endif
        view.send(txt: "stty -echo; printf '\\n\(marker)\\n'\n")
        try await waitUntil { self.text(view).contains("\n\(marker)\n") }
        if let directory = configuration.workingDirectory {
          let escaped = directory.replacingOccurrences(of: "'", with: "'\\''")
          view.send(txt: "cd '\(escaped)'; pwd; ls -la\n")
        }
        view.send(txt: "printf '\\033[32mConnDock 中文🙂\\033[0m\\n'\n")
        try await waitUntil { self.text(view).contains("ConnDock 中文🙂") }
      }
      XCTAssertFalse(text(first.surface.view).contains("__SESSION_B__"))
      XCTAssertFalse(text(second.surface.view).contains("__SESSION_A__"))
      await workspace.connectSavedHost(hostIDs[1])
      XCTAssertEqual(workspace.selection, secondTab)
      XCTAssertEqual(workspace.tabs.count, 2, "Opening an active saved host should select its tab")
      let lastConnected = store.host(hostIDs[0])?.lastConnectedAt
      await workspace.connectSavedHost(hostIDs[0], testOnly: true)
      let testTab = workspace.selection
      let testSession = try XCTUnwrap(workspace.selectedSession)
      try await waitUntil { !testSession.isActive }
      XCTAssertTrue(testSession.testSucceeded, "Connection testing must authenticate a real PTY")
      XCTAssertEqual(testSession.statusKey, "hosts.testSucceeded")
      XCTAssertEqual(store.host(hostIDs[0])?.lastConnectedAt, lastConnected)
      workspace.closeTab(testTab)
      workspace.selection = secondTab
      #if os(macOS)
        let content = try XCTUnwrap(window.contentView)
        try await waitUntil { self.attached(second.surface.view, beneath: content) }
      #else
        try await waitUntil { self.attached(second.surface.view, beneath: window) }
      #endif
      let columnsBeforeFontChange = second.columns
      preferences.terminalFontSize = 15
      try await waitUntil { second.surface.view.font.pointSize == 15 }
      try await waitUntil { second.columns != columnsBeforeFontChange }
      XCTAssertEqual(second.surface.view.font.pointSize, 15)
      preferences.terminalFontSize = 13
      try await waitUntil { second.surface.view.font.pointSize == 13 }
      try await Task.sleep(for: .milliseconds(200))
      if configuration.captureScreenshots { capture(window, variant: "zh-dark", phase: "phase2") }
      preferences.language = .english
      preferences.appearance = .light
      try await waitUntil { self.hasLightBackground(second.surface.view) }
      XCTAssertTrue(first.isConnected && second.isConnected)
      second.surface.view.send(txt: "printf '\\n__PERSISTED_LIVE__\\n'\n")
      try await waitUntil { self.text(second.surface.view).contains("\n__PERSISTED_LIVE__\n") }
      try await Task.sleep(for: .milliseconds(200))
      if configuration.captureScreenshots { capture(window, variant: "en-light", phase: "phase2") }
      // Deleting a saved configuration must not silently close an existing SSH session.
      try await store.deleteHost(hostIDs[0])
      XCTAssertTrue(first.isConnected)
      workspace.closeTab(firstTab)
      XCTAssertFalse(first.isActive)
      XCTAssertTrue(second.isConnected)
      second.disconnect()
      try await waitUntil { !second.isActive }
    } catch {
      for tab in workspace.tabs { workspace.closeTab(tab.id) }
      for id in hostIDs where store.host(id) != nil { try? await store.deleteHost(id) }
      for reference in references { try? await vault.delete(reference: reference) }
      throw error
    }
    for tab in workspace.tabs { workspace.closeTab(tab.id) }
    for id in hostIDs where store.host(id) != nil { try await store.deleteHost(id) }
    for reference in references {
      let remaining = try await vault.load(reference: reference)
      XCTAssertNil(remaining, "Temporary integration credentials must be removed from Keychain")
    }
    XCTAssertFalse(store.cleanupPending)
  }

  func testSFTPAndLinuxMonitorThroughBridge() async throws {
    let configuration = try takeConfiguration()
    let privateKey = try XCTUnwrap(configuration.privateKey)
    let workingDirectory = try XCTUnwrap(configuration.workingDirectory)
    guard configuration.host == "127.0.0.1", configuration.isolatedFixture == true,
      !workingDirectory.isEmpty
    else {
      throw IntegrationError.invalidConfiguration
    }
    let ownedDirectoryName = "Phase3-\(configuration.runIdentifier.uuidString)"
    let ownedDirectory = try RemotePaths.child(workingDirectory, name: ownedDirectoryName)
    let domain = "ConnDock.Phase3.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = .dark
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let library = try HostLibrary(
      storeURL: directory.appendingPathComponent("Hosts.store"),
      vault: KeychainCredentialStorage(service: domain), cleanupDefaults: defaults)
    let workspace = WorkspaceState(library: library, trustDefaults: defaults)
    let root = WorkspaceRoot().environment(preferences).environment(workspace).environment(
      \.scenePhase, .active)
    #if os(macOS)
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1360, height: 880),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "ConnDock"
      window.contentView = NSHostingView(rootView: root)
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
    #else
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = scene.coordinateSpace.bounds
      window.rootViewController = UIHostingController(rootView: root)
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
    #endif
    workspace.connect(
      target: ConnectionTarget(
        displayName: "Linux OpenSSH", host: configuration.host,
        port: configuration.port, username: configuration.username, usesPrivateKey: true),
      authentication: .ed25519(privateKey: privateKey, passphrase: configuration.passphrase))
    let session = try XCTUnwrap(workspace.selectedSession)
    defer { session.close() }
    try await waitUntil { workspace.trustPrompt != nil || !session.isActive }
    let challenge = try XCTUnwrap(workspace.trustPrompt)
    guard challenge.fingerprint == configuration.fingerprint else {
      workspace.resolveTrust(challenge: challenge, accept: false)
      throw IntegrationError.hostKeyMismatch
    }
    workspace.resolveTrust(challenge: challenge, accept: true)
    try await waitUntil { session.isConnected || !session.isActive }
    XCTAssertTrue(session.isConnected)
    let files = try XCTUnwrap(session.files)
    let monitor = try XCTUnwrap(session.monitor)
    session.surface.view.send(txt: "stty -echo; printf '\\n__PHASE3_PTY__\\n'\n")
    try await waitUntil { self.text(session.surface.view).contains("\n__PHASE3_PTY__\n") }
    #if os(iOS)
      workspace.presentedTool = .files
    #endif
    try await waitUntil { files.path != nil && !files.isLoading }
    files.browse(workingDirectory)
    try await waitUntil { files.path == workingDirectory && !files.isLoading }
    XCTAssertNil(files.errorKey)
    await files.createDirectory(name: ownedDirectoryName)
    try await waitUntil { !files.isLoading }
    guard files.errorKey == nil, files.entries.contains(where: { $0.name == ownedDirectoryName })
    else { throw IntegrationError.invalidConfiguration }
    files.browse(ownedDirectory)
    try await waitUntil { files.path == ownedDirectory && !files.isLoading }
    let source = directory.appendingPathComponent("中文🙂 ' ; $(id).bin")
    let payload = Data((0..<1_048_583).map { UInt8($0 % 251) })
    try payload.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let selectedSource = try FileUploadSource(url: source)
    let oldDestination = try XCTUnwrap(files.uploadDestination)
    files.browse(workingDirectory)
    try await waitUntil { files.path == workingDirectory && !files.isLoading }
    files.browse(ownedDirectory)
    try await waitUntil { files.path == ownedDirectory && !files.isLoading }
    let countBeforeSelection = files.transfers.count
    XCTAssertFalse(files.upload(selectedSource, to: oldDestination))
    XCTAssertEqual(files.errorKey, "sftp.error.staleSelection")
    XCTAssertEqual(files.transfers.count, countBeforeSelection)
    let destination = try XCTUnwrap(files.uploadDestination)
    XCTAssertTrue(files.upload(selectedSource, to: destination))
    let upload = try XCTUnwrap(files.transfers.last)
    try await waitUntil { upload.status == .completed || upload.status == .failed }
    XCTAssertEqual(upload.status, .completed)
    XCTAssertEqual(upload.bytesTransferred, UInt64(payload.count))
    XCTAssertEqual(upload.fractionCompleted, 1)
    try await waitUntil {
      !files.isLoading && files.entries.contains { $0.name == source.lastPathComponent }
    }
    let entry = try XCTUnwrap(files.entries.first { $0.name == source.lastPathComponent })
    await files.rename(entry, to: "renamed-中文.bin")
    try await waitUntil {
      !files.isLoading && files.entries.contains { $0.name == "renamed-中文.bin" }
    }
    let renamed = try XCTUnwrap(files.entries.first { $0.name == "renamed-中文.bin" })
    await files.remove(renamed, in: workingDirectory)
    XCTAssertEqual(
      files.errorKey, "sftp.error.staleSelection",
      "An entry confirmed in another directory must not affect this directory's namesake")
    XCTAssertTrue(files.entries.contains { $0.name == "renamed-中文.bin" })
    files.download(renamed)
    let download = try XCTUnwrap(files.transfers.last)
    try await waitUntil { download.status == .completed || download.status == .failed }
    XCTAssertEqual(download.status, .completed)
    XCTAssertEqual(download.fractionCompleted, 1)
    let downloadedURL = try XCTUnwrap(download.downloadedURL)
    XCTAssertEqual(try Data(contentsOf: downloadedURL), payload)
    let retrySource = directory.appendingPathComponent("retry-中文.bin")
    files.upload(retrySource)
    let retry = try XCTUnwrap(files.transfers.last)
    try await waitUntil { retry.status == .failed }
    XCTAssertEqual(retry.errorKey, "sftp.error.localFile")
    try payload.write(to: retrySource)
    defer { try? FileManager.default.removeItem(at: retrySource) }
    files.retry(retry)
    try await waitUntil { retry.status == .completed || retry.status == .failed }
    XCTAssertEqual(
      retry.status, .completed,
      "A failed local source must be retryable through the same real SSH session")
    let cancelledSource = directory.appendingPathComponent("cancelled.bin")
    try payload.write(to: cancelledSource)
    defer { try? FileManager.default.removeItem(at: cancelledSource) }
    files.upload(cancelledSource)
    let cancelled = try XCTUnwrap(files.transfers.last)
    files.cancel(cancelled)
    try await waitUntil { cancelled.status == .cancelled }
    await files.createDirectory(name: "目录验收")
    try await waitUntil { !files.isLoading && files.entries.contains { $0.name == "目录验收" } }
    if configuration.captureScreenshots {
      capture(window, variant: "zh-dark-files", phase: "phase3")
    }
    preferences.language = .english
    preferences.appearance = .light
    #if os(iOS)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(
        window.rootViewController?.presentedViewController?.traitCollection.userInterfaceStyle,
        .light, "An already presented SFTP sheet must immediately adopt light appearance")
    #endif
    try await Task.sleep(for: .milliseconds(300))
    if configuration.captureScreenshots {
      capture(window, variant: "en-light-files", phase: "phase3")
    }
    #if os(iOS)
      workspace.presentedTool = nil
      try await Task.sleep(for: .milliseconds(700))
      workspace.presentedTool = .monitor
    #endif
    if configuration.expectLinux == true {
      try await waitUntil { monitor.latest?.cpuPercent != nil || monitor.errorKey != nil }
      XCTAssertNil(monitor.errorKey)
      let metrics = try XCTUnwrap(monitor.latest)
      XCTAssertGreaterThan(metrics.memoryTotal, 0)
      XCTAssertGreaterThan(metrics.diskTotal, 0)
      XCTAssertTrue((0...100).contains(try XCTUnwrap(metrics.cpuPercent)))
      XCTAssertNotNil(metrics.receiveBytesPerSecond)
      if configuration.captureScreenshots {
        capture(window, variant: "en-light-monitor", phase: "phase3")
      }
      preferences.language = .simplifiedChinese
      preferences.appearance = .dark
      #if os(iOS)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
          window.rootViewController?.presentedViewController?.traitCollection.userInterfaceStyle,
          .dark, "An already presented monitor sheet must immediately adopt dark appearance")
      #endif
      try await Task.sleep(for: .milliseconds(300))
      if configuration.captureScreenshots {
        capture(window, variant: "zh-dark-monitor", phase: "phase3")
      }
      monitor.togglePaused()
      let sampledAt = monitor.sampledAt
      try await Task.sleep(for: .milliseconds(5200))
      XCTAssertEqual(monitor.sampledAt, sampledAt)
      monitor.togglePaused()
      try await waitUntil { monitor.sampledAt != sampledAt }
    } else {
      try await waitUntil { monitor.errorKey != nil }
      XCTAssertEqual(monitor.errorKey, "monitor.unsupported")
    }
    #if os(macOS)
      preferences.inspectorVisible = false
    #else
      workspace.presentedTool = nil
    #endif
    try await waitUntil { !monitor.isCollecting }
    let hiddenSample = monitor.sampledAt
    try await Task.sleep(for: .milliseconds(5200))
    XCTAssertEqual(monitor.sampledAt, hiddenSample, "Hidden panels must stop collecting")
    XCTAssertTrue(session.isConnected)
    session.surface.view.send(txt: "printf '\\n__PHASE3_STILL_LIVE__\\n'\n")
    try await waitUntil { self.text(session.surface.view).contains("\n__PHASE3_STILL_LIVE__\n") }
    #if os(iOS)
      workspace.presentedTool = .files
      try await Task.sleep(for: .milliseconds(500))
    #endif
    files.browse(ownedDirectory)
    try await waitUntil { files.path == ownedDirectory && !files.isLoading }
    for entry in files.entries {
      await files.remove(entry, in: ownedDirectory)
      try await waitUntil { !files.isLoading }
    }
    files.browse(workingDirectory)
    try await waitUntil { files.path == workingDirectory && !files.isLoading }
    if let owned = files.entries.first(where: { $0.name == ownedDirectoryName }) {
      await files.remove(owned, in: workingDirectory)
      try await waitUntil { !files.isLoading }
      XCTAssertNil(files.errorKey)
    }
    files.clearFinishedTransfers()
    session.disconnect()
    try await waitUntil { !session.isActive }
    XCTAssertFalse(files.isConnected)
    XCTAssertFalse(monitor.isCollecting)
    XCTAssertNil(monitor.latest)
  }

  private func text(_ view: TerminalView) -> String {
    let terminal = view.getTerminal()
    return (0..<bufferLineCount(terminal)).compactMap { row in
      terminal.getScrollInvariantLine(row: row)?.translateToString(
        trimRight: true,
        skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) })
    }.joined(separator: "\n") + "\n"
  }

  private func bufferLineCount(_ terminal: Terminal) -> Int {
    terminal.getBufferAsData().reduce(0) { $1 == 10 ? $0 + 1 : $0 }
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
  ) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Real SSH condition did not complete within 10 seconds", file: file, line: line)
    throw IntegrationError.deadline
  }
  private enum IntegrationError: Error { case deadline, hostKeyMismatch, invalidConfiguration }

  #if os(macOS)
    private func hasLightBackground(_ view: TerminalView) -> Bool {
      guard let color = view.nativeBackgroundColor.usingColorSpace(.deviceRGB) else { return false }
      return abs(color.redComponent - 1) < 0.001
    }
    private func attached(_ view: NSView, beneath root: NSView) -> Bool {
      root === view || root.subviews.contains { attached(view, beneath: $0) }
    }

    private func capture(_ window: NSWindow, variant: String, phase: String = "phase1") {
      // AppKit's cacheDisplay does not capture the transparent backing of a
      // layer-hosted light SwiftTerm reliably. Light-mode UI screenshots come
      // from XCUITest's actual window screenshot; do not export a blank image.
      guard !variant.hasPrefix("en-light") else { return }
      guard let content = window.contentView,
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
      else { return }
      content.displayIfNeeded()
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let image = NSImage(size: content.bounds.size)
      image.addRepresentation(bitmap)
      let attachment = XCTAttachment(image: image)
      attachment.name = "macos-\(phase)-\(variant)-ssh-live"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  #else
    private func hasLightBackground(_ view: TerminalView) -> Bool {
      var red: CGFloat = 0
      view.nativeBackgroundColor.getRed(&red, green: nil, blue: nil, alpha: nil)
      return abs(red - 1) < 0.001
    }
    private func attached(_ view: UIView, beneath root: UIView) -> Bool {
      root === view || root.subviews.contains { attached(view, beneath: $0) }
    }

    private func capture(_ window: UIWindow, variant: String, phase: String = "phase1") {
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name =
        UIDevice.current.userInterfaceIdiom == .pad
        ? "ipad-\(phase)-\(variant)-ssh-live" : "iphone-\(phase)-\(variant)-ssh-live"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  #endif
}
