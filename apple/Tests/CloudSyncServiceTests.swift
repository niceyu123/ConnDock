import Foundation
import XCTest

@testable import ConnDockKit

@MainActor
private final class MockCloudServer {
  var account: String? = "account-A"
  var offline = false
  var copies: [String: [String: SyncRecordSnapshot]] = [:]
  var zones: Set<String> = []
}

/// Test-only transport. This does not run in the App or claim to validate CloudKit.
@MainActor
private final class MockSyncTransport: CloudSyncTransport {
  let server: MockCloudServer
  var handlers: SyncTransportHandlers?
  var names: Set<String> = []
  var beforeAcknowledgement: (() async throws -> Void)?
  var deleteCount = 0
  init(_ server: MockCloudServer) { self.server = server }
  func accountIdentifier() async throws -> String {
    guard let account = server.account else { throw CloudSyncFailure.signedOut }
    return account
  }
  func start(state: Data?, handlers: SyncTransportHandlers) throws { self.handlers = handlers }
  func enqueue(_ identities: [SyncIdentity]) { names.formUnion(identities.map(\.recordName)) }
  func synchronize() async throws {
    guard !server.offline else { throw CloudSyncFailure.network }
    let account = try await accountIdentifier()
    let handlers = try XCTUnwrap(handlers)
    if handlers.expectsExistingZone && !server.zones.contains(account) {
      throw CloudSyncFailure.zoneRemoved
    }
    server.zones.insert(account)
    try await handlers.event(.records(Array(server.copies[account, default: [:]].values)))
    let outgoing = try handlers.records(Array(names))
    try await beforeAcknowledgement?()
    beforeAcknowledgement = nil
    for snapshot in outgoing {
      server.copies[account, default: [:]][snapshot.document.identity.recordName] = snapshot
    }
    try await handlers.event(.records(outgoing))
    try await handlers.event(.state(Data([1])))
  }
  func stop() {}
  func deleteZone() async throws {
    let account = try await accountIdentifier()
    server.copies[account] = [:]
    server.zones.remove(account)
    deleteCount += 1
  }
}

@MainActor
final class CloudSyncServiceTests: XCTestCase {
  private func store() throws -> HostLibrary {
    try HostLibrary(
      memoryOnly: true,
      cleanupDefaults: try XCTUnwrap(
        UserDefaults(suiteName: "ConnDock.SyncServiceTests.\(UUID())")))
  }

  func testTwoServicesReplicateAndOfflineEditsRetryWithoutLosingLocalData() async throws {
    let server = MockCloudServer()
    let a = try store()
    let b = try store()
    let ta = MockSyncTransport(server)
    let tb = MockSyncTransport(server)
    let sa = CloudSyncService(library: a, factory: { ta })
    let sb = CloudSyncService(library: b, factory: { tb })
    defer {
      sa.disable()
      sb.disable()
    }
    let host = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await sa.enable()
    await sb.enable()
    XCTAssertTrue(sa.isEnabled)
    XCTAssertEqual(b.hosts.map(\.id), [host.id])
    server.offline = true
    try a.toggleFavorite(host.id)
    await sa.syncNow()
    XCTAssertEqual(sa.failure, .network)
    XCTAssertEqual(try a.syncRecords(pendingOnly: true).count, 1)
    XCTAssertTrue(try XCTUnwrap(a.host(host.id)).favorite)
    server.offline = false
    await sa.syncNow()
    await sb.syncNow()
    XCTAssertTrue(try XCTUnwrap(b.host(host.id)).favorite)
    XCTAssertTrue(try a.syncRecords(pendingOnly: true).isEmpty)
    try await a.deleteHost(host.id)
    await sa.syncNow()
    await sb.syncNow()
    XCTAssertTrue(b.hosts.isEmpty)
  }

  func testLateAcknowledgementLeavesNewerEditPending() async throws {
    let server = MockCloudServer()
    let a = try store()
    let actual = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { actual })
    defer { service.disable() }
    let host = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    actual.beforeAcknowledgement = { try a.toggleFavorite(host.id) }
    await service.enable()
    XCTAssertTrue(try XCTUnwrap(a.host(host.id)).favorite)
    XCTAssertEqual(try a.syncRecords(pendingOnly: true).count, 1)
    await service.syncNow()
    XCTAssertTrue(try a.syncRecords(pendingOnly: true).isEmpty)
  }

  func testDisableRejectsLateEventsAndKeepsLocalRows() async throws {
    let server = MockCloudServer()
    let a = try store()
    let transport = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { transport })
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await service.enable()
    let handlers = try XCTUnwrap(transport.handlers)
    service.disable()
    do {
      try await handlers.event(.state(Data([77])))
      XCTFail("Disabled run accepted a late state token")
    } catch {}
    XCTAssertEqual(a.hosts.count, 1)
    XCTAssertFalse(try a.syncSettings().enabled)
    XCTAssertNotEqual(try a.syncSettings().engineState, Data([77]))
  }

  func testAccountSwitchStopsBeforeUploadingToNewAccountAndRequiresReenable() async throws {
    let server = MockCloudServer()
    let a = try store()
    let transport = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { transport })
    defer { service.disable() }
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await service.enable()
    server.account = "account-B"
    await service.syncNow()
    XCTAssertFalse(service.isEnabled)
    XCTAssertEqual(service.failure, .accountChanged)
    XCTAssertTrue(server.copies["account-B", default: [:]].isEmpty)
    XCTAssertEqual(a.hosts.count, 1)
    await service.enable()
    XCTAssertEqual(server.copies["account-B"]?.count, 1)
  }

  func testCloudCopyDeletionDisablesSyncAndPreservesLocalHosts() async throws {
    let server = MockCloudServer()
    let a = try store()
    let transport = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { transport })
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await service.enable()
    await service.deleteCloudCopy()
    XCTAssertFalse(service.isEnabled)
    XCTAssertEqual(transport.deleteCount, 1)
    XCTAssertTrue(server.copies["account-A", default: [:]].isEmpty)
    XCTAssertEqual(a.hosts.count, 1)
    XCTAssertNil(try a.syncSettings().engineState)
  }

  func testAccountChangeCanPersistDisableWhileCredentialCleanupOwnsLibrary() async throws {
    let server = MockCloudServer()
    let a = try store()
    let transport = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { transport })
    defer { service.disable() }
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await service.enable()
    try a.beginRemoteMerge()
    server.account = "account-B"
    await service.syncNow()
    a.endRemoteMerge()
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(
      try a.syncSettings().enabled, "Account change must be durable even during Keychain cleanup")
    XCTAssertNil(try a.syncSettings().engineState)
    XCTAssertEqual(service.failure, .accountChanged)
  }

  func testSigningOutDisablesDurablyAndRequiresExplicitReenable() async throws {
    let server = MockCloudServer()
    let a = try store()
    let transport = MockSyncTransport(server)
    let service = CloudSyncService(library: a, factory: { transport })
    defer { service.disable() }
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await service.enable()
    server.account = nil
    await service.syncNow()
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(try a.syncSettings().enabled)
    XCTAssertEqual(service.failure, .signedOut)
    XCTAssertEqual(a.hosts.count, 1)
    server.account = "account-A"
    await service.syncNow()
    XCTAssertFalse(
      service.isEnabled, "Signing in again must not bypass the upload scope confirmation")
  }

  func testUnconfiguredBuildNeverRestartsPreviouslyEnabledState() async throws {
    guard !CloudSyncConfiguration.current.isConfigured else {
      throw XCTSkip("Requires the Local configuration")
    }
    let a = try store()
    try a.configureSync(enabled: true, account: "previous-account")
    let service = CloudSyncService(library: a)
    defer { service.disable() }
    XCTAssertFalse(service.isConfigured)
    XCTAssertFalse(service.isEnabled)
    await service.syncNow()
    XCTAssertFalse(service.isSyncing)
  }

  func testDeletingCloudCopyStopsPreviouslySyncedDeviceBeforeItRecreatesZone() async throws {
    let server = MockCloudServer()
    let a = try store()
    let b = try store()
    let ta = MockSyncTransport(server)
    let tb = MockSyncTransport(server)
    let sa = CloudSyncService(library: a, factory: { ta })
    let sb = CloudSyncService(library: b, factory: { tb })
    defer {
      sa.disable()
      sb.disable()
    }
    _ = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"))
    await sa.enable()
    await sb.enable()
    await sa.deleteCloudCopy()
    await sb.syncNow()
    XCTAssertFalse(sb.isEnabled)
    XCTAssertEqual(sb.failure, .zoneRemoved)
    XCTAssertEqual(b.hosts.count, 1)
    XCTAssertFalse(
      server.zones.contains("account-A"),
      "An old device must not silently recreate the deleted cloud copy")
  }
}
