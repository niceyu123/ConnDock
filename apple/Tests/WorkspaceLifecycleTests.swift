import Foundation
import XCTest

@testable import ConnDockKit

private actor PausedCredentialStorage: CredentialStorage {
  private var value: SavedCredential?
  private var continuation: CheckedContinuation<SavedCredential?, Never>?
  private(set) var isLoading = false
  func store(_ value: SavedCredential, reference: String) { self.value = value }
  func load(reference: String) async -> SavedCredential? {
    isLoading = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func delete(reference: String) { value = nil }
  func resume() {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

@MainActor
final class WorkspaceLifecycleTests: XCTestCase {
  func testClosingOriginatingTabInvalidatesPendingCredentialRead() async throws {
    let domain = "ConnDock.ClosedTab.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let vault = PausedCredentialStorage()
    let library = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let host = try await library.saveHost(
      HostDraft(displayName: "Paused", hostname: "example.invalid", username: "test"),
      credential: .password(UUID().uuidString), rememberCredential: true)
    let workspace = WorkspaceState(library: library, trustDefaults: defaults)
    workspace.addTerminal()
    let origin = workspace.selection
    let opening = Task { await workspace.connectSavedHost(host.id, newTab: true) }
    for _ in 0..<100 {
      if await vault.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let isLoading = await vault.isLoading
    XCTAssertTrue(isLoading)
    workspace.closeTab(origin)
    await vault.resume()
    await opening.value
    XCTAssertNil(workspace.selectedSession)
    XCTAssertEqual(workspace.tabs.count, 1)
    XCTAssertFalse(workspace.showNewHost)
  }

  func testBackgroundInvalidatesCredentialReadEvenAfterReturningToForeground() async throws {
    let domain = "ConnDock.WorkspaceLifecycle.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let vault = PausedCredentialStorage()
    let library = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
    let host = try await library.saveHost(
      HostDraft(displayName: "Paused", hostname: "example.invalid", username: "test"),
      credential: .password(UUID().uuidString), rememberCredential: true)
    let workspace = WorkspaceState(library: library, trustDefaults: defaults)
    let opening = Task { await workspace.connectSavedHost(host.id, newTab: true) }
    for _ in 0..<100 {
      if await vault.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let isLoading = await vault.isLoading
    XCTAssertTrue(isLoading)
    workspace.setApplicationBackgrounded(true)
    workspace.setApplicationBackgrounded(false)
    await vault.resume()
    await opening.value
    XCTAssertNil(workspace.selectedSession)
    XCTAssertEqual(workspace.tabs.count, 1)
    XCTAssertEqual(workspace.operationErrorKey, "ssh.error.backgroundCancelled")
    XCTAssertFalse(workspace.showNewHost)
  }
}
