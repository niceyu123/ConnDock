import Foundation
import XCTest

@testable import ConnDockKit

final class KeychainTests: XCTestCase {
  @MainActor
  func testAutomationRequiresNoninteractiveCredentialStoragePath() async throws {
    let vault = AutomationOnlyCredentialStorage()
    let defaults = UserDefaults(suiteName: "ConnDock.AutomationKeychain.\(UUID())")!
    let library = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let host = try await library.saveHost(
      HostDraft(displayName: "Test", hostname: "example.invalid", username: "test"),
      credential: .password("test-only"), rememberCredential: true)
    let value = try await library.credential(for: host, allowsUserInteraction: false)
    XCTAssertEqual(value, .password("test-only"))
    let interactiveCalls = await vault.interactiveCalls
    let automationCalls = await vault.automationCalls
    XCTAssertEqual(interactiveCalls, 0)
    XCTAssertEqual(automationCalls, 1)
  }

  func testRealSystemKeychainRoundTripAndDeletion() async throws {
    let vault = KeychainCredentialStorage(service: "ConnDock.KeychainTests.\(UUID().uuidString)")
    let reference = UUID().uuidString
    let secret = SavedCredential.password(UUID().uuidString)
    do {
      try await vault.store(secret, reference: reference)
      let noninteractive = try await vault.loadForAutomation(reference: reference)
      XCTAssertEqual(noninteractive, secret)
      let restored = try await vault.load(reference: reference)
      XCTAssertEqual(restored, secret)
      try await vault.delete(reference: reference)
      let deleted = try await vault.load(reference: reference)
      XCTAssertNil(deleted)
    } catch {
      try? await vault.delete(reference: reference)
      throw error
    }
  }
}

private actor AutomationOnlyCredentialStorage: CredentialStorage {
  var interactiveCalls = 0
  var automationCalls = 0
  var value: SavedCredential?
  func store(_ value: SavedCredential, reference: String) { self.value = value }
  func load(reference: String) throws -> SavedCredential? {
    interactiveCalls += 1
    throw CredentialStorageError.unavailable
  }
  func loadForAutomation(reference: String) -> SavedCredential? {
    automationCalls += 1
    return value
  }
  func delete(reference: String) { value = nil }
}
