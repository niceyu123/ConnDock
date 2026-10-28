import CloudKit
import Foundation
import SwiftData
import XCTest

@testable import ConnDockKit

private actor SyncCredentialVault: CredentialStorage {
  var values: [String: SavedCredential] = [:]
  func store(_ value: SavedCredential, reference: String) { values[reference] = value }
  func load(reference: String) -> SavedCredential? { values[reference] }
  func delete(reference: String) { values.removeValue(forKey: reference) }
}

@MainActor
final class CloudSyncTests: XCTestCase {
  private func store(url: URL? = nil) throws -> HostLibrary {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConnDock.SyncTests.\(UUID())"))
    return try HostLibrary(storeURL: url, memoryOnly: url == nil, cleanupDefaults: defaults)
  }

  private func addHost(_ library: HostLibrary) async throws -> StoredHost {
    try await library.saveHost(
      HostDraft(displayName: "中文 Server", hostname: "example.invalid", username: "tester"))
  }

  func testLocalChangesAreDurableAndRecentConnectionIsNotSynced() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sync-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Hosts.store")
    let a = try store(url: url)
    let host = try await addHost(a)
    let first = try XCTUnwrap(a.syncRecords(pendingOnly: true).first)
    try a.markConnected(host.id)
    XCTAssertEqual(try a.syncRecords(pendingOnly: true).first?.document, first.document)
    let b = try store(url: url)
    XCTAssertEqual(try b.syncRecords(pendingOnly: true).first?.document, first.document)
    XCTAssertFalse(try b.syncSettings().enabled)
  }

  func testCloudRecordContainsOnlyAnEncryptedWhitelistedDocument() async throws {
    let a = try store()
    _ = try await addHost(a)
    let snapshot = try XCTUnwrap(a.syncRecords().first)
    let record = try CloudKitRecordCodec.record(from: snapshot)
    XCTAssertEqual(record.recordID.recordName, snapshot.document.identity.recordName)
    XCTAssertFalse(record.recordID.recordName.contains("example.invalid"))
    XCTAssertEqual(
      Set(record.allKeys()), Set(record.encryptedValues.allKeys()),
      "Every application field must be registered as encrypted")
    XCTAssertEqual(Set(record.encryptedValues.allKeys()), ["payloadV1"])
    let decoded = try CloudKitRecordCodec.snapshot(from: record)
    XCTAssertEqual(decoded.document, snapshot.document)
    let json = try JSONSerialization.jsonObject(with: snapshot.document.encoded())
    func keys(_ object: Any) -> Set<String> {
      if let dictionary = object as? [String: Any] {
        return Set(dictionary.keys).union(
          dictionary.values.reduce(into: Set<String>()) { $0.formUnion(keys($1)) })
      }
      if let array = object as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) }
      }
      return []
    }
    for forbidden in [
      "credentialRef", "password", "privateKey", "lastConnected", "fingerprint", "terminalTheme",
    ] {
      XCTAssertFalse(keys(json).contains(forbidden), forbidden)
    }
  }

  func testTwoStoresConvergeAcrossCreateEditAndDelete() async throws {
    let a = try store()
    let b = try store()
    let group = try a.createGroup(name: "生产环境")
    let host = try await addHost(a)
    var draft = HostDraft(host: host)
    draft.groupID = group.id
    draft.tags = ["生产", "Linux", "linux"]
    _ = try await a.saveHost(draft)
    try await b.applySyncRecords(a.syncRecords())
    XCTAssertEqual(b.host(host.id)?.groupID, group.id)
    XCTAssertNil(b.host(host.id)?.credentialRef)
    XCTAssertEqual(b.tags(for: host.id), ["生产", "Linux"])
    XCTAssertEqual(b.matching(search: "Linux").map(\.id), [host.id])
    try b.toggleFavorite(host.id)
    try await a.applySyncRecords(b.syncRecords())
    XCTAssertTrue(try XCTUnwrap(a.host(host.id)).favorite)
    try await a.deleteHost(host.id)
    try await b.applySyncRecords(a.syncRecords())
    XCTAssertNil(b.host(host.id))
    XCTAssertTrue(
      try XCTUnwrap(b.syncRecords().first { $0.document.identity == .host(host.id) }).document
        .deleted)
  }

  func testV1DiskMigrationKeepsHostIdentityCredentialReferenceAndCreatesOutbox() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SyncMigration-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Hosts.store")
    let hostID = UUID()
    try autoreleasepool {
      let schema = Schema(versionedSchema: HostSchemaV1.self)
      let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let container = try ModelContainer(for: schema, configurations: [config])
      let context = ModelContext(container)
      context.autosaveEnabled = false
      let host = StoredHost(
        id: hostID, displayName: "V1", hostname: "example.invalid", port: 22, username: "user",
        authMethod: .password)
      host.credentialRef = "reference-only"
      context.insert(host)
      // V1 allowed internal whitespace in group names; sync must not make that store unreadable.
      context.insert(StoredHostGroup(name: "Legacy\tGroup"))
      try context.save()
    }
    let migrated = try store(url: url)
    XCTAssertEqual(migrated.hosts.map(\.id), [hostID])
    XCTAssertEqual(migrated.host(hostID)?.credentialRef, "reference-only")
    XCTAssertEqual(try migrated.syncRecords(pendingOnly: true).count, 2)
    XCTAssertEqual(migrated.tags(for: hostID), [])
    XCTAssertEqual(migrated.groups.map(\.name), ["Legacy\tGroup"])
    XCTAssertFalse(try migrated.syncSettings().enabled)
  }

  func testOldAcknowledgementCannotClearANewerLocalEdit() async throws {
    let a = try store()
    let host = try await addHost(a)
    let sent = try a.syncRecords()
    try a.toggleFavorite(host.id)
    try await a.applySyncRecords(sent)
    XCTAssertTrue(try XCTUnwrap(a.host(host.id)).favorite)
    let pending = try a.syncRecords(pendingOnly: true)
    XCTAssertEqual(pending.count, 1)
    XCTAssertNotEqual(pending.first?.document, sent.first?.document)
  }

  func testConcurrentEditsAndOfflineDeleteConvergeWithoutResurrection() async throws {
    let a = try store()
    let b = try store()
    let host = try await addHost(a)
    try await b.applySyncRecords(a.syncRecords())
    var aDraft = HostDraft(host: try XCTUnwrap(a.host(host.id)))
    aDraft.notes = "A edit"
    _ = try await a.saveHost(aDraft)
    var bDraft = HostDraft(host: try XCTUnwrap(b.host(host.id)))
    bDraft.notes = "B edit"
    _ = try await b.saveHost(bDraft)
    let aVersion = try a.syncRecords()
    let bVersion = try b.syncRecords()
    try await a.applySyncRecords(bVersion)
    try await b.applySyncRecords(aVersion)
    XCTAssertEqual(a.host(host.id)?.notes, b.host(host.id)?.notes)
    let offlineEdit = try a.syncRecords()
    try await b.deleteHost(host.id)
    try await a.applySyncRecords(b.syncRecords())
    try await b.applySyncRecords(offlineEdit)
    XCTAssertNil(a.host(host.id))
    XCTAssertNil(b.host(host.id))
  }

  func testGroupDeletionAndOutOfOrderHostDeliveryCannotRestoreDeletedGroup() async throws {
    let a = try store()
    let b = try store()
    let group = try a.createGroup(name: "Group")
    let host = try await addHost(a)
    var draft = HostDraft(host: host)
    draft.groupID = group.id
    _ = try await a.saveHost(draft)
    let old = try a.syncRecords()
    try a.deleteGroup(group.id)
    try await b.applySyncRecords(a.syncRecords())
    try await b.applySyncRecords(old)
    XCTAssertTrue(b.groups.isEmpty)
    XCTAssertNil(b.host(host.id)?.groupID)
  }

  func testDisableAndAccountRebindPreserveLocalHostsButResetRemoteState() async throws {
    let a = try store()
    let host = try await addHost(a)
    try a.configureSync(enabled: true, account: "account-A", resetRemote: true)
    try a.persistSyncEngineState(Data([1, 2, 3]))
    try a.configureSync(enabled: false)
    XCTAssertNotNil(a.host(host.id))
    XCTAssertEqual(try a.syncSettings().account, "account-A")
    try a.configureSync(enabled: true, account: "account-B", resetRemote: true)
    XCTAssertNil(try a.syncSettings().engineState)
    XCTAssertEqual(try a.syncSettings().account, "account-B")
    XCTAssertEqual(try a.syncRecords(pendingOnly: true).count, 1)
  }

  func testRemoteIdentityChangeInvalidatesOnlyLocalCredentialAndPayloadExcludesSecret() async throws
  {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConnDock.SyncCredentialTests.\(UUID())"))
    let vault = SyncCredentialVault()
    let a = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let b = try store()
    let secret = UUID().uuidString + UUID().uuidString
    let host = try await a.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "user"),
      credential: .password(secret), rememberCredential: true)
    let reference = try XCTUnwrap(host.credentialRef)
    let outgoing = try a.syncRecords()
    XCTAssertNil(try outgoing[0].document.encoded().range(of: Data(secret.utf8)))
    try await b.applySyncRecords(outgoing)
    XCTAssertNil(b.host(host.id)?.credentialRef)
    var draft = HostDraft(host: try XCTUnwrap(b.host(host.id)))
    draft.hostname = "other.invalid"
    _ = try await b.saveHost(draft)
    try await a.applySyncRecords(b.syncRecords())
    XCTAssertNil(a.host(host.id)?.credentialRef)
    let retired = await vault.load(reference: reference)
    XCTAssertTrue(retired == nil)
  }

  func testInvalidBatchCannotPartiallyApplyOrAdvanceEngineState() async throws {
    let a = try store()
    let b = try store()
    _ = try await addHost(a)
    let good = try XCTUnwrap(a.syncRecords().first)
    var badDocument = good.document
    badDocument.schemaVersion = 99
    do {
      try await b.applySyncRecords([good, SyncRecordSnapshot(document: badDocument)])
      XCTFail("Invalid batch applied")
    } catch {}
    XCTAssertTrue(b.hosts.isEmpty)
    XCTAssertNil(try b.syncSettings().engineState)
  }

  func testCloudRecordCodecRejectsPlaintextPayloadAndMismatchedRecordID() async throws {
    let a = try store()
    _ = try await addHost(a)
    let snapshot = try XCTUnwrap(a.syncRecords().first)
    let plain = CKRecord(
      recordType: CloudKitRecordCodec.recordType,
      recordID: CKRecord.ID(
        recordName: snapshot.document.identity.recordName, zoneID: CloudKitRecordCodec.zoneID))
    plain["payloadV1"] = try snapshot.document.encoded() as NSData
    XCTAssertThrowsError(try CloudKitRecordCodec.snapshot(from: plain))
    let mismatch = CKRecord(
      recordType: CloudKitRecordCodec.recordType,
      recordID: CKRecord.ID(
        recordName: SyncIdentity.host(UUID()).recordName, zoneID: CloudKitRecordCodec.zoneID))
    mismatch.encryptedValues["payloadV1"] = try snapshot.document.encoded() as NSData
    XCTAssertThrowsError(try CloudKitRecordCodec.snapshot(from: mismatch))
  }

  func testFailedOutboxStagingRollsBackHostEditInSameTransaction() async throws {
    let a = try store()
    let host = try await addHost(a)
    let original = try XCTUnwrap(a.syncRecords().first)
    a.context.insert(try StoredSyncRecord(document: original.document))
    XCTAssertThrowsError(try a.toggleFavorite(host.id))
    XCTAssertFalse(try XCTUnwrap(a.host(host.id)).favorite)
    XCTAssertEqual(try a.syncRecords().count, 1)
    XCTAssertEqual(try a.syncRecords().first?.document, original.document)
  }
}
