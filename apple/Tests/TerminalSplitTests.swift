import Foundation
import XCTest

@testable import ConnDockKit

#if os(macOS)
  import AppKit
  import SwiftUI
#endif

@MainActor
final class TerminalSplitTests: XCTestCase {
  private func workspace() throws -> WorkspaceState {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConnDock.Split.\(UUID().uuidString)"))
    let library = try HostLibrary(memoryOnly: true, cleanupDefaults: defaults)
    return WorkspaceState(library: library, trustDefaults: defaults)
  }

  func testSplitCreatesIndependentEmptyTabAndSelectingEitherKeepsBothVisible() throws {
    let workspace = try workspace()
    let first = workspace.selection
    workspace.splitSelected(axis: .horizontal)
    let second = workspace.selection
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(workspace.visibleTerminalTabs.map(\.id), [first, second])
    XCTAssertEqual(workspace.selectedSplit?.axis, .horizontal)
    workspace.selection = first
    XCTAssertEqual(workspace.visibleTerminalTabs.map(\.id), [first, second])
    XCTAssertNil(workspace.session(for: first))
    XCTAssertNil(workspace.session(for: second))
    workspace.splitSelected(axis: .vertical)
    XCTAssertEqual(workspace.tabs.count, 2, "Changing direction must not create another session")
    XCTAssertEqual(workspace.selectedSplit?.axis, .vertical)
  }

  func testJoiningPreservesTabsAndClosingOnePaneSelectsCompanion() throws {
    let workspace = try workspace()
    let first = workspace.selection
    workspace.splitSelected(axis: .horizontal)
    let second = workspace.selection
    workspace.joinSelectedSplit()
    XCTAssertEqual(workspace.tabs.count, 2)
    XCTAssertEqual(workspace.visibleTerminalTabs.map(\.id), [second])
    workspace.splitSelected(with: first, axis: .vertical)
    workspace.addTerminal()
    let unrelated = workspace.selection
    workspace.selection = second
    workspace.closeTab(second)
    XCTAssertEqual(workspace.selection, first)
    XCTAssertNil(workspace.selectedSplit)
    XCTAssertTrue(workspace.tabs.contains { $0.id == unrelated })
    workspace.closeTab(first)
    workspace.closeTab(unrelated)
    XCTAssertEqual(workspace.tabs.count, 1)
    XCTAssertTrue(workspace.tabs[0].isWelcome)
  }

  func testRegroupingNeverDisplaysSameTabTwiceOrClosesOtherTabs() throws {
    let workspace = try workspace()
    let first = workspace.selection
    workspace.splitSelected(axis: .horizontal)
    let second = workspace.selection
    workspace.addTerminal()
    let third = workspace.selection
    workspace.splitSelected(with: second, axis: .vertical)
    XCTAssertEqual(workspace.visibleTerminalTabs.map(\.id), [third, second])
    XCTAssertEqual(workspace.tabs.count, 3)
    workspace.selection = first
    XCTAssertNil(workspace.selectedSplit)
    workspace.splitSelected(with: first, axis: .horizontal)
    workspace.splitSelected(with: UUID(), axis: .horizontal)
    XCTAssertEqual(workspace.visibleTerminalTabs.map(\.id), [first])
    workspace.selection = second
    workspace.closeTab(third)
    XCTAssertEqual(workspace.selection, second)
    XCTAssertNil(workspace.selectedSplit)
  }

  func testSplitReusesLiveSessionAndFocusSelectsExactTarget() throws {
    let workspace = try workspace()
    let first = workspace.selection
    workspace.connect(
      target: ConnectionTarget(
        displayName: "Test", host: "example.invalid", port: 22, username: "test",
        usesPrivateKey: false), authentication: .password(password: ""))
    let session = try XCTUnwrap(workspace.selectedSession)
    session.close()
    workspace.splitSelected(axis: .horizontal)
    let second = workspace.selection
    XCTAssertTrue(workspace.session(for: first) === session)
    session.onFocus?()
    XCTAssertEqual(workspace.selection, first)
    workspace.joinSelectedSplit()
    XCTAssertTrue(workspace.selectedSession === session)
    XCTAssertTrue(workspace.tabs.contains { $0.id == second })
    workspace.closeTab(first)
    session.onFocus?()
    XCTAssertNotEqual(workspace.selection, first, "Late focus must not revive a closed tab")
  }

  func testTerminalProtocolReplyCannotChangeSelectedPane() throws {
    let workspace = try workspace()
    workspace.connect(
      target: ConnectionTarget(
        displayName: "Test", host: "example.invalid", port: 22, username: "test",
        usesPrivateKey: false), authentication: .password(password: ""))
    let session = try XCTUnwrap(workspace.selectedSession)
    session.close()
    workspace.splitSelected(axis: .horizontal)
    let focused = workspace.selection
    let surface = session.surface
    // SwiftTerm uses the send delegate for automatic replies to DSR/DA queries too.
    surface.send(source: surface.view, data: [27, 91, 49, 59, 49, 82][...])
    XCTAssertEqual(workspace.selection, focused)
  }

  #if os(macOS)
    func testFocusRequestedBeforeAttachmentIsRestoredOnlyForTheCurrentPane() throws {
      for changeSelection in [false, true] {
        let workspace = try workspace()
        let tab = workspace.selection
        workspace.connect(
          target: ConnectionTarget(
            displayName: "Test", host: "example.invalid", port: 22, username: "test",
            usesPrivateKey: false), authentication: .password(password: ""))
        let session = try XCTUnwrap(workspace.selectedSession)
        session.close()
        let window = NSWindow(
          contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        let view = session.surface.view
        workspace.activateTerminal(tab)
        if changeSelection { workspace.addTerminal() }
        window.contentView?.addSubview(view)
        XCTAssertEqual(window.firstResponder === view, !changeSelection)
      }
    }

    func testNativeFocusSurvivesDirectionChangeAndJoining() async throws {
      let workspace = try workspace()
      let first = workspace.selection
      workspace.connect(
        target: ConnectionTarget(
          displayName: "Test", host: "example.invalid", port: 22, username: "test",
          usesPrivateKey: false), authentication: .password(password: ""))
      let session = try XCTUnwrap(workspace.selectedSession)
      session.close()
      workspace.splitSelected(axis: .horizontal)
      workspace.selection = first
      let preferences = AppPreferences(
        defaults: try XCTUnwrap(UserDefaults(suiteName: "ConnDock.SplitFocus.\(UUID())")))
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: TerminalWorkspace(showTabs: false).environment(preferences).environment(workspace)
      )
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      let view = session.surface.view
      func waitForFocus() async throws -> Bool {
        for _ in 0..<60 {
          if window.firstResponder === view && view.window === window { return true }
          try await Task.sleep(for: .milliseconds(20))
        }
        return false
      }
      let initial = try await waitForFocus()
      XCTAssertTrue(initial)
      workspace.splitSelected(axis: .vertical)
      try await Task.sleep(for: .milliseconds(100))
      let afterDirection = try await waitForFocus()
      XCTAssertTrue(
        afterDirection, "Changing layout must restore the selected native input surface")
      workspace.joinSelectedSplit()
      try await Task.sleep(for: .milliseconds(100))
      let afterJoin = try await waitForFocus()
      XCTAssertTrue(afterJoin, "Joining must restore the selected native input surface")
    }
  #endif
}
