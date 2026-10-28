import Foundation
import XCTest

@testable import ConnDockKit

private actor SSHConfigCredentialTrap: CredentialStorage {
  func store(_ value: SavedCredential, reference: String) throws {
    XCTFail("Import must never write credentials")
    throw CredentialStorageError.unavailable
  }
  func load(reference: String) throws -> SavedCredential? {
    XCTFail("Import must never load credentials")
    throw CredentialStorageError.unavailable
  }
  func delete(reference: String) throws { XCTFail("Import must never delete credentials") }
}

@MainActor
final class SSHConfigImportTests: XCTestCase {
  func testImportAddsSelectedSafeHostsWithoutSecretsAndStagesSyncChanges() async throws {
    let store = try HostLibrary(memoryOnly: true, vault: SSHConfigCredentialTrap())
    let result = try SSHConfigParser.parse(
      """
      User engineer
      Host first
        HostName first.invalid
        IdentityFile ~/.ssh/not-read
      Host second
        HostName second.invalid
      Host unsafe
        ProxyCommand do-not-run
      """)
    let report = await SSHConfigImporter.save(
      result.entries, selectedIDs: Set(result.entries.map(\.id)), to: store)
    XCTAssertEqual(report.importedCount, 2)
    XCTAssertEqual(report.skippedCount, 1)
    XCTAssertNil(report.errorKey)
    XCTAssertEqual(store.hosts.map(\.displayName), ["first", "second"])
    XCTAssertTrue(store.hosts.allSatisfy { $0.credentialRef == nil && $0.lastConnectedAt == nil })
    XCTAssertEqual(store.hosts.first?.authMethod, .ed25519)
    XCTAssertEqual(try store.syncRecords(pendingOnly: true).count, 2)
    let payload = try XCTUnwrap(try store.syncRecords().first?.document.encoded())
    XCTAssertNil(String(data: payload, encoding: .utf8)?.range(of: "not-read"))
  }

  func testRepeatedImportAndExistingAliasOrEndpointNeverOverwriteExistingHosts() async throws {
    let store = try HostLibrary(memoryOnly: true, vault: SSHConfigCredentialTrap())
    let original = try await store.saveHost(
      HostDraft(displayName: "Existing", hostname: "existing.invalid", username: "engineer"))
    let result = try SSHConfigParser.parse(
      """
      User engineer
      Host existing
        HostName changed.invalid
      Host duplicate
        HostName EXISTING.invalid
      Host fresh
        HostName fresh.invalid
      """)
    let selected = Set(result.entries.map(\.id))
    let first = await SSHConfigImporter.save(result.entries, selectedIDs: selected, to: store)
    XCTAssertEqual(first.importedCount, 1)
    XCTAssertEqual(first.skippedCount, 2)
    XCTAssertEqual(store.host(original.id)?.hostname, "existing.invalid")
    XCTAssertEqual(store.host(original.id)?.syncRevision, 1)
    let second = await SSHConfigImporter.save(result.entries, selectedIDs: selected, to: store)
    XCTAssertEqual(second.importedCount, 0)
    XCTAssertEqual(second.skippedCount, 3)
    XCTAssertEqual(store.hosts.count, 2)
  }

  func testSelectionAndBusyStoreReportExactlyWhatWasNotSaved() async throws {
    let store = try HostLibrary(memoryOnly: true, vault: SSHConfigCredentialTrap())
    let result = try SSHConfigParser.parse("User engineer\nHost first second\n")
    try store.beginRemoteMerge()
    let blocked = await SSHConfigImporter.save(
      result.entries, selectedIDs: ["first"], to: store)
    store.endRemoteMerge()
    XCTAssertEqual(blocked.importedCount, 0)
    XCTAssertEqual(blocked.remainingCount, 1)
    XCTAssertEqual(blocked.errorKey, "storage.error.busy")
    XCTAssertTrue(store.hosts.isEmpty)
    let saved = await SSHConfigImporter.save(result.entries, selectedIDs: ["second"], to: store)
    XCTAssertEqual(saved.importedCount, 1)
    XCTAssertEqual(store.hosts.first?.displayName, "second")
  }
}
