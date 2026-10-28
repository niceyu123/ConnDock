import Foundation
import SSHCoreBridge
import SwiftTerm
import XCTest

@testable import ConnDockKit

extension SSHIntegrationTests {
  func testSessionLifecycleRecoveryAndRepeatedTabs() async throws {
    let configuration = try takeConfiguration()
    guard configuration.isolatedFixture == true, configuration.host == "127.0.0.1" else {
      throw StabilityError.invalidFixture
    }
    let key = try XCTUnwrap(configuration.privateKey)
    let domain = "ConnDock.Stability.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    try HostTrustStore(defaults: defaults).remember(
      host: configuration.host, port: configuration.port, algorithm: "ssh-ed25519",
      fingerprint: configuration.fingerprint)
    let library = try HostLibrary(
      memoryOnly: true, vault: KeychainCredentialStorage(service: domain), cleanupDefaults: defaults
    )
    let workspace = WorkspaceState(library: library, trustDefaults: defaults)
    defer { for tab in workspace.tabs { workspace.closeTab(tab.id) } }
    let target = ConnectionTarget(
      displayName: "Isolated stability fixture", host: configuration.host, port: configuration.port,
      username: configuration.username, usesPrivateKey: true)
    let auth = AuthenticationRequest.ed25519(privateKey: key, passphrase: configuration.passphrase)
    var sessions: [TerminalSession] = []
    for _ in 0..<3 {
      workspace.connect(target: target, authentication: auth)
      let session = try XCTUnwrap(workspace.selectedSession)
      try await stabilityWait { session.isConnected || !session.isActive }
      XCTAssertTrue(session.isConnected)
      sessions.append(session)
    }
    // One channel ends while polling is paused. Recovery must fail just that
    // session, while verifying the two surviving transports before input resumes.
    let ended = try XCTUnwrap(sessions.last)
    ended.send(Array("sleep 0.3; exit\n".utf8))
    try await stabilityWait { self.stabilityText(ended).contains("sleep 0.3; exit") }
    workspace.setApplicationBackgrounded(true)
    for session in sessions {
      XCTAssertTrue(session.isSuspended)
      XCTAssertFalse(session.isConnected)
      session.send(Array("printf '__MUST_NOT_BE_REPLAYED__'\n".utf8))
    }
    try await Task.sleep(for: .milliseconds(500))
    workspace.setApplicationBackgrounded(false)
    try await stabilityWait { sessions.allSatisfy { !$0.isSuspended && !$0.isCheckingConnection } }
    XCTAssertFalse(ended.isActive)
    XCTAssertFalse(ended.isConnected)
    for (index, session) in sessions.dropLast().enumerated() {
      XCTAssertTrue(session.isConnected)
      let marker = "__RESUMED_\(index)__"
      session.send(Array("stty -echo; printf '\\n\(marker)\\n'\n".utf8))
      try await stabilityWait { self.stabilityText(session).contains("\n\(marker)\n") }
      XCTAssertFalse(stabilityText(session).contains("__MUST_NOT_BE_REPLAYED__"))
    }
    // Retain the native view after removing each tab; neither the polling task
    // nor the native surface may keep its closed TerminalSession alive.
    for cycle in 0..<12 {
      workspace.addTerminal()
      let tab = workspace.selection
      weak var released: TerminalSession?
      var retainedSurface: TerminalSurface?
      do {
        workspace.connect(target: target, authentication: auth)
        let session = try XCTUnwrap(workspace.selectedSession)
        released = session
        retainedSurface = session.surface
        try await stabilityWait { session.isConnected || !session.isActive }
        XCTAssertTrue(session.isConnected)
        if cycle.isMultiple(of: 3) {
          session.enterBackground()
          session.restoreForeground()
        }
        workspace.closeTab(tab)
      }
      try await stabilityWait { released == nil }
      XCTAssertNil(released)
      XCTAssertNotNil(retainedSurface)
    }
    XCTAssertTrue(sessions.dropLast().allSatisfy(\.isConnected))
    XCTAssertEqual(workspace.tabs.count, 3)
  }

  private func stabilityText(_ session: TerminalSession) -> String {
    let terminal = session.surface.view.getTerminal()
    let rows = terminal.getBufferAsData().reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    return (0..<rows).compactMap { row in
      terminal.getScrollInvariantLine(row: row)?.translateToString(
        trimRight: true, skipNullCellsFollowingWide: true,
        characterProvider: { terminal.getCharacter(for: $0) })
    }.joined(separator: "\n") + "\n"
  }

  private func stabilityWait(_ condition: () -> Bool) async throws {
    for _ in 0..<750 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Isolated lifecycle condition timed out after 15 seconds")
    throw StabilityError.deadline
  }

  private enum StabilityError: Error { case invalidFixture, deadline }
}
