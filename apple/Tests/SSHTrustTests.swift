import Foundation
import SSHCoreBridge
import XCTest

@testable import ConnDockKit

@MainActor
final class SSHTrustTests: XCTestCase {
  func testStaleTrustPromptCannotApproveTheNextQueuedHost() throws {
    let domain = "ConnDock.TrustTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let library = try HostLibrary(memoryOnly: true, cleanupDefaults: defaults)
    let workspace = WorkspaceState(library: library, trustDefaults: defaults)
    let target = ConnectionTarget(
      displayName: "", host: "example.test", port: 0, username: "test", usesPrivateKey: false)
    // Invalid port is rejected before networking. This tests the prompt
    // coordinator and session lifecycle, independently of the SSH transport.
    workspace.connect(target: target, authentication: .password(password: ""))
    let tabID = workspace.selection
    let sessionID = try XCTUnwrap(workspace.selectedSession).id
    let first = HostKeyChallenge(
      id: sessionID, target: target, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:" + String(repeating: "A", count: 43))
    let second = HostKeyChallenge(
      id: UUID(), target: target, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:" + String(repeating: "B", count: 43))
    workspace.enqueueTrust(first)
    workspace.enqueueTrust(second)
    workspace.closeTab(tabID)
    XCTAssertEqual(workspace.trustPrompt?.id, second.id)
    XCTAssertFalse(workspace.resolveTrust(challenge: first, accept: true))
    XCTAssertEqual(workspace.trustPrompt?.id, second.id)
  }

  #if os(macOS)
    func testLocalShellRunsCommandsAndSurvivesTabSwitch() async throws {
      let domain = "ConnDock.LocalShellTests.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
      defer { defaults.removePersistentDomain(forName: domain) }
      let library = try HostLibrary(memoryOnly: true, cleanupDefaults: defaults)
      let workspace = WorkspaceState(library: library, trustDefaults: defaults)
      workspace.openLocalTerminal()
      let tab = workspace.selection
      let shell = try XCTUnwrap(workspace.selectedLocalShell)
      defer { workspace.closeTab(tab) }
      XCTAssertTrue(shell.view.process.running)
      workspace.addTerminal()
      workspace.selection = tab
      XCTAssertTrue(workspace.selectedLocalShell === shell)
      let command = "printf 'CONNDOCK_LOCAL_%s\\n' OK\n"
      shell.view.process.send(data: Array(command.utf8)[...])
      var output = ""
      for _ in 0..<250 {
        let terminal = shell.view.getTerminal()
        let count = terminal.getBufferAsData().reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        output = (0..<count).compactMap { row in
          terminal.getScrollInvariantLine(row: row)?.translateToString(
            trimRight: true, skipNullCellsFollowingWide: true,
            characterProvider: { terminal.getCharacter(for: $0) })
        }.joined(separator: "\n")
        if output.contains("CONNDOCK_LOCAL_OK") { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(output.contains("CONNDOCK_LOCAL_OK"))
      workspace.closeTab(tab)
      XCTAssertFalse(shell.view.process.running)
    }
  #endif

  func testArrowsRespectTheRemoteApplicationCursorMode() {
    XCTAssertEqual(TerminalInput.arrow("arrow.up", applicationCursor: false), [27, 91, 65])
    XCTAssertEqual(TerminalInput.arrow("arrow.left", applicationCursor: true), [27, 79, 68])
  }
  func testTrustIsLocalPersistentAndScopedByHostAndPort() throws {
    let domain = "ConnDock.TrustTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = HostTrustStore(defaults: defaults)
    let fp = "SHA256:" + String(repeating: "A", count: 43)
    XCTAssertNil(try store.fingerprint(host: "example.test", port: 22))
    try store.remember(host: "EXAMPLE.test", port: 22, algorithm: "ssh-ed25519", fingerprint: fp)
    let restored = HostTrustStore(defaults: defaults)
    XCTAssertEqual(try restored.fingerprint(host: "example.test", port: 22), fp)
    XCTAssertNil(try restored.fingerprint(host: "example.test", port: 2222))
    XCTAssertThrowsError(
      try restored.remember(
        host: "example.test", port: 22,
        algorithm: "ssh-ed25519", fingerprint: "SHA256:" + String(repeating: "B", count: 43)))
  }

  func testCorruptTrustRecordsFailClosed() throws {
    let domain = "ConnDock.TrustTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(Data("corrupt".utf8), forKey: "ssh.hostTrust.v1")
    let store = HostTrustStore(defaults: defaults)
    XCTAssertTrue(store.isCorrupt)
    XCTAssertThrowsError(try store.fingerprint(host: "example.test", port: 22))
  }

  func testNewSshStatusesAndErrorsAreTranslated() {
    for language in AppLanguage.allCases {
      for key in [
        "ssh.state.connected", "ssh.error.hostKeyChanged", "ssh.error.authenticationFailed",
        "ssh.trust.title", "ssh.credentials.memoryOnly",
      ] {
        XCTAssertNotEqual(L10n.text(key, language: language), key)
      }
    }
  }

  func testSessionMapsTypedEventsWithoutRetainingCredentials() {
    let target = ConnectionTarget(
      displayName: "", host: "example.test", port: 22,
      username: "test", usesPrivateKey: false)
    let session = TerminalSession(id: UUID(), target: target)
    session.consume([.stateChanged(state: .authenticating)])
    XCTAssertEqual(session.statusKey, "ssh.state.authenticating")
    session.consume([.ended(reason: .failure, error: .authenticationFailed, exitStatus: nil)])
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.failure?.localizationKey, "ssh.error.authenticationFailed")
  }
}
