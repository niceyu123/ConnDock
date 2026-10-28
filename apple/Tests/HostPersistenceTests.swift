import Foundation
import XCTest

@testable import ConnDockKit

private actor TestCredentialStorage: CredentialStorage {
  var items: [String: SavedCredential] = [:]
  var rejectWrites = false
  var rejectDeletes = false
  func store(_ value: SavedCredential, reference: String) throws {
    if rejectWrites { throw CredentialStorageError.unavailable }
    items[reference] = value
  }
  func load(reference: String) -> SavedCredential? { items[reference] }
  func delete(reference: String) throws {
    if rejectDeletes { throw CredentialStorageError.unavailable }
    items.removeValue(forKey: reference)
  }
  func setRejectWrites() { rejectWrites = true }
  func setRejectDeletes(_ value: Bool) { rejectDeletes = value }
}

@MainActor
final class HostPersistenceTests: XCTestCase {
  private func isolatedDefaults() throws -> (UserDefaults, String) {
    let domain = "ConnDock.StoreTests.\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: domain)), domain)
  }

  func testDiskReopenPersistsMetadataAndKeepsSecretsOutsideSwiftData() async throws {
    let (defaults, domain) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: domain) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnDock.StoreTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Do not unlink SQLite files while SwiftData retains open store handles.
    // This per-run temporary directory contains metadata, never credentials.
    let vault = TestCredentialStorage()
    let secret = UUID().uuidString + UUID().uuidString
    let store = try HostLibrary(
      storeURL: folder.appendingPathComponent("hosts.store"), vault: vault,
      cleanupDefaults: defaults)
    let group = try store.createGroup(name: "Test group")
    var draft = HostDraft(
      displayName: "Saved connection", hostname: "example.invalid", username: "tester")
    draft.groupID = group.id
    let saved = try await store.saveHost(
      draft, credential: .password(secret), rememberCredential: true)
    let reference = try XCTUnwrap(saved.credentialRef)
    let credential = try await store.credential(for: saved)
    XCTAssertEqual(credential, .password(secret))
    let reopened = try HostLibrary(
      storeURL: folder.appendingPathComponent("hosts.store"), vault: vault,
      cleanupDefaults: defaults)
    XCTAssertEqual(reopened.hosts.count, 1)
    XCTAssertEqual(reopened.hosts.first?.id, saved.id)
    XCTAssertEqual(reopened.hosts.first?.groupID, group.id)
    XCTAssertEqual(reopened.hosts.first?.credentialRef, reference)
    for file in try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    {
      let bytes = try Data(contentsOf: file)
      XCTAssertNil(
        bytes.range(of: Data(secret.utf8)), "SwiftData files must never contain an SSH password")
    }
  }

  func testIdentityChangeInvalidatesSavedCredentialAndGroupDeletionPreservesHost() async throws {
    let (defaults, domain) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: domain) }
    let vault = TestCredentialStorage()
    let store = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let group = try store.createGroup(name: "Test group")
    var draft = HostDraft(displayName: "Saved", hostname: "example.invalid", username: "tester")
    draft.groupID = group.id
    let saved = try await store.saveHost(
      draft, credential: .password(UUID().uuidString), rememberCredential: true)
    let oldReference = try XCTUnwrap(saved.credentialRef)
    var changed = HostDraft(host: saved)
    changed.hostname = "other.invalid"
    let updated = try await store.saveHost(changed, rememberCredential: true)
    XCTAssertNil(updated.credentialRef, "A secret must not silently follow a changed SSH identity")
    let oldCredential = await vault.load(reference: oldReference)
    XCTAssertNil(oldCredential)
    try store.deleteGroup(group.id)
    XCTAssertEqual(store.hosts.count, 1)
    XCTAssertNil(store.hosts.first?.groupID)
  }

  func testCredentialWriteFailureCannotCommitHostAndStaleEditsAreRejected() async throws {
    let (defaults, domain) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: domain) }
    let vault = TestCredentialStorage()
    let store = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let draft = HostDraft(displayName: "Saved", hostname: "example.invalid", username: "tester")
    await vault.setRejectWrites()
    do {
      _ = try await store.saveHost(
        draft, credential: .password(UUID().uuidString), rememberCredential: true)
      XCTFail("A failed Keychain write must fail the save")
    } catch {}
    XCTAssertTrue(store.hosts.isEmpty)
    let saved = try await store.saveHost(draft)
    let stale = HostDraft(host: saved)
    try store.toggleFavorite(saved.id)
    do {
      _ = try await store.saveHost(stale)
      XCTFail("A stale edit must not overwrite a newer configuration")
    } catch HostLibraryError.conflict {}
  }

  func testSearchFavoritesAndDeletionUseRealPersistedRows() async throws {
    let (defaults, domain) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = try HostLibrary(
      memoryOnly: true, vault: TestCredentialStorage(), cleanupDefaults: defaults)
    let saved = try await store.saveHost(
      HostDraft(displayName: "中文 Server", hostname: "example.invalid", username: "tester"))
    XCTAssertEqual(store.matching(search: "server").map(\.id), [saved.id])
    XCTAssertTrue(store.matching(favoritesOnly: true).isEmpty)
    try store.toggleFavorite(saved.id)
    XCTAssertEqual(store.matching(favoritesOnly: true).count, 1)
    try store.markConnected(saved.id)
    XCTAssertEqual(store.matching(recentOnly: true).count, 1)
    try await store.deleteHost(saved.id)
    XCTAssertTrue(store.hosts.isEmpty)
  }

  func testCredentialRemovalRetriesAfterKeychainFailureAndGroupEditsDetectConflicts() async throws {
    let (defaults, domain) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: domain) }
    let vault = TestCredentialStorage()
    let store = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let saved = try await store.saveHost(
      HostDraft(displayName: "Saved", hostname: "example.invalid", username: "tester"),
      credential: .password(UUID().uuidString), rememberCredential: true)
    let reference = try XCTUnwrap(saved.credentialRef)
    await vault.setRejectDeletes(true)
    try await store.deleteHost(saved.id)
    XCTAssertTrue(store.hosts.isEmpty)
    XCTAssertTrue(store.cleanupPending)
    await vault.setRejectDeletes(false)
    await store.retryCredentialCleanup()
    XCTAssertFalse(store.cleanupPending)
    let remaining = await vault.load(reference: reference)
    XCTAssertNil(remaining)

    let group = try store.createGroup(name: "Original")
    let originalRevision = group.syncRevision
    try store.renameGroup(group.id, name: "Renamed", expectedRevision: originalRevision)
    XCTAssertThrowsError(
      try store.renameGroup(group.id, name: "Stale", expectedRevision: originalRevision))
    XCTAssertThrowsError(try store.createGroup(name: "renamed"))
    XCTAssertEqual(store.groups.first?.name, "Renamed")
  }
}
