import Foundation
import SSHCoreBridge
import SwiftData
import XCTest

@testable import ConnDockKit

@MainActor
final class AdvancedConnectionTests: XCTestCase {
  func testLegacyOfflineEditCannotRemoveAnAdvancedRoute() async throws {
    let library = try HostLibrary(memoryOnly: true)
    let jump = try await library.saveHost(
      HostDraft(displayName: "Jump", hostname: "jump.invalid", username: "test"))
    let target = try await library.saveHost(
      HostDraft(displayName: "Target", hostname: "target.invalid", username: "test"))
    let legacy = try XCTUnwrap(
      library.syncRecords().first { $0.document.identity == .host(target.id) }?.document)
    var edit = HostDraft(host: target)
    edit.connectionOptions = HostConnectionOptions(jumpHostID: jump.id)
    _ = try await library.saveHost(edit)
    let offline = SyncDocument(
      identity: legacy.identity,
      version: SyncVersion(counter: 100, device: UUID(), mutation: UUID()), deleted: false,
      createdAt: legacy.createdAt, updatedAt: Date(), host: legacy.host)
    try await library.applySyncRecords([SyncRecordSnapshot(document: offline)])
    XCTAssertEqual(library.connectionOptions(for: target.id).jumpHostID, jump.id)
    let retained = try XCTUnwrap(
      library.syncRecords().first { $0.document.identity == .host(target.id) })
    XCTAssertEqual(retained.document.schemaVersion, 2)
    XCTAssertTrue(retained.pending)
  }

  func testNewClientCanExplicitlyRemoveAnAdvancedRouteWithoutDowngradingSchema() async throws {
    let library = try HostLibrary(memoryOnly: true)
    let jump = try await library.saveHost(
      HostDraft(displayName: "Jump", hostname: "jump.invalid", username: "test"))
    var draft = HostDraft(displayName: "Target", hostname: "target.invalid", username: "test")
    draft.connectionOptions = HostConnectionOptions(jumpHostID: jump.id)
    let target = try await library.saveHost(draft)
    let other = try HostLibrary(memoryOnly: true)
    try await other.applySyncRecords(library.syncRecords())
    var edit = HostDraft(host: target)
    edit.connectionOptions = HostConnectionOptions()
    _ = try await library.saveHost(edit)
    let direct = try XCTUnwrap(
      library.syncRecords().first { $0.document.identity == .host(target.id) })
    XCTAssertEqual(direct.document.schemaVersion, 2)
    try await other.applySyncRecords([direct])
    XCTAssertNil(other.connectionOptions(for: target.id).jumpHostID)
  }

  func testReconnectRetainsUnsavedRouteAndTransportMode() {
    let workspace = WorkspaceState()
    let target = ConnectionTarget(
      displayName: "Target", host: "example.invalid", port: 22, username: "test",
      usesPrivateKey: false)
    let options = HostConnectionOptions(filesOnly: true, jumpHostID: UUID(), allowInteractive: true)
    let jump = TerminalSession(id: UUID(), target: target)
    workspace.connect(
      target: target, authentication: .keyboardInteractive, options: options, jump: jump)
    workspace.selectedSession?.close()
    workspace.requestReconnect()
    XCTAssertEqual(workspace.reconnectOptions, options)
    workspace.finishHostEditing()
    XCTAssertNil(workspace.reconnectOptions)
  }

  func testRejectedConnectionClosesItsPreparedJump() throws {
    let workspace = WorkspaceState()
    workspace.setApplicationBackgrounded(true)
    let target = ConnectionTarget(
      displayName: "Target", host: "example.invalid", port: 22, username: "test",
      usesPrivateKey: false)
    let jump = TerminalSession(id: UUID(), target: target)
    workspace.connect(
      target: target, authentication: .keyboardInteractive,
      options: HostConnectionOptions(jumpHostID: UUID()), jump: jump)
    XCTAssertFalse(jump.isActive)
    XCTAssertNil(workspace.selectedSession)
  }

  func testAgentAuthorizationCannotBeReusedForAnotherSocketDirectory() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "AgentFixture")
    XCTAssertNoThrow(
      try AgentSocketAccess(
        directory: directory, socketPath: directory.appendingPathComponent("agent.sock").path))
    XCTAssertThrowsError(
      try AgentSocketAccess(
        directory: directory, socketPath: directory.appendingPathComponent("other/agent.sock").path)
    )
    XCTAssertThrowsError(try HostConnectionOptions(agentFingerprint: "SHA256:invalid").validate())
  }
  func testV3StoreMigratesWithoutChangingExistingCredentialsOrTargets() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnDock.V3.\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Hosts.store")
    let id: UUID
    do {
      let schema = Schema(versionedSchema: HostSchemaV3.self)
      let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      let host = StoredHost(
        displayName: "V3", hostname: "old.invalid", port: 22, username: "old", authMethod: .password
      )
      host.credentialRef = "opaque-reference"
      id = host.id
      context.insert(host)
      try context.save()
    }
    let store = try HostLibrary(storeURL: url)
    XCTAssertEqual(store.host(id)?.hostname, "old.invalid")
    XCTAssertEqual(store.host(id)?.credentialRef, "opaque-reference")
    XCTAssertEqual(store.connectionOptions(for: id), HostConnectionOptions())
    XCTAssertEqual(try store.syncRecords().first?.document.schemaVersion, 1)
  }

  func testInteractiveAnswersStayBoundToCurrentRoundAndClosedSessionsIgnoreLatePrompts() {
    let session = TerminalSession(
      id: UUID(),
      target: ConnectionTarget(
        displayName: "MFA", host: "example.invalid", port: 22, username: "test",
        usesPrivateKey: false))
    let prompts = [AuthenticationPrompt(prompt: "Token", echo: false)]
    session.consume([
      .authenticationChallenge(id: 1, name: "One", instructions: "", prompts: prompts)
    ])
    let stale = session.authenticationChallenge!
    session.consume([
      .authenticationChallenge(id: 2, name: "Two", instructions: "", prompts: prompts)
    ])
    session.respondAuthentication(stale, responses: ["stale"])
    XCTAssertEqual(session.authenticationChallenge?.requestID, 2)
    session.enterBackground()
    XCTAssertNil(session.authenticationChallenge)
    session.consume([
      .authenticationChallenge(id: 3, name: "Late", instructions: "", prompts: prompts)
    ])
    XCTAssertNil(session.authenticationChallenge)
  }

  func testAdvancedOptionsPersistAndSyncWithoutAgentSocketOrCredentials() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnDock.Advanced.\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Hosts.store")
    let store = try HostLibrary(storeURL: url)
    let jump = try await store.saveHost(
      HostDraft(displayName: "Jump", hostname: "jump.invalid", username: "jump"))
    var draft = HostDraft(
      displayName: "Files", hostname: "internal.invalid", username: "files",
      authMethod: .keyboardInteractive)
    draft.connectionOptions = HostConnectionOptions(
      filesOnly: true, jumpHostID: jump.id, allowInteractive: true)
    let host = try await store.saveHost(draft)
    let reopened = try HostLibrary(storeURL: url)
    XCTAssertEqual(reopened.connectionOptions(for: host.id), draft.connectionOptions)
    let document = try XCTUnwrap(
      store.syncRecords().first { $0.document.identity == .host(host.id) }?.document)
    XCTAssertEqual(document.schemaVersion, 2)
    let other = try HostLibrary(memoryOnly: true)
    try await other.applySyncRecords(store.syncRecords())
    XCTAssertEqual(other.connectionOptions(for: host.id), draft.connectionOptions)
    XCTAssertNil(other.host(host.id)?.credentialRef)
    let json = String(decoding: try document.encoded(), as: UTF8.self)
    XCTAssertFalse(json.contains("agentSocket"))
    XCTAssertFalse(json.contains("privateKey"))
    XCTAssertEqual(other.host(host.id)?.authMethod, .keyboardInteractive)
  }

  func testMissingNestedAndSelfJumpAreRejectedWithoutDirectFallback() async throws {
    let store = try HostLibrary(memoryOnly: true)
    var draft = HostDraft(displayName: "Target", hostname: "target.invalid", username: "test")
    draft.connectionOptions = HostConnectionOptions(jumpHostID: UUID())
    do {
      _ = try await store.saveHost(draft)
      XCTFail("missing jump")
    } catch {}
    draft.connectionOptions = HostConnectionOptions()
    let first = try await store.saveHost(draft)
    var edit = HostDraft(host: first)
    edit.connectionOptions = HostConnectionOptions(jumpHostID: first.id)
    do {
      _ = try await store.saveHost(edit)
      XCTFail("self jump")
    } catch {}
    var second = HostDraft(displayName: "Second", hostname: "second.invalid", username: "test")
    second.connectionOptions = HostConnectionOptions(jumpHostID: first.id)
    let nested = try await store.saveHost(second)
    draft.connectionOptions = HostConnectionOptions(jumpHostID: nested.id)
    do {
      _ = try await store.saveHost(draft)
      XCTFail("nested jump")
    } catch {}
  }
}
