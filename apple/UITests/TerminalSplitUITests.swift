import XCTest

#if os(iOS)
  import UIKit
#endif

@MainActor
final class TerminalSplitUITests: XCTestCase {
  func testTabletSplitMenuAndPhoneImportEntry() throws {
    #if os(iOS)
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launchEnvironment["CONNDOCK_UI_TESTING"] = "1"
      app.launchEnvironment["CONNDOCK_RESET_PREFERENCES"] = "1"
      XCUIDevice.shared.orientation =
        UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
      app.launch()
      if UIDevice.current.userInterfaceIdiom == .pad {
        let menu = app.buttons["terminalSplitMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        app.buttons["左右分屏"].tap()
        let panes = app.buttons.matching(
          NSPredicate(format: "identifier BEGINSWITH %@", "terminalPaneFocus."))
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(panes.count, 2)
        let window = app.windows.firstMatch.frame
        for pane in panes.allElementsBoundByIndex {
          XCTAssertGreaterThanOrEqual(pane.frame.minX, window.minX)
          XCTAssertLessThanOrEqual(pane.frame.maxX, window.maxX + 1)
          XCTAssertGreaterThanOrEqual(pane.frame.minY, window.minY)
          XCTAssertLessThanOrEqual(pane.frame.maxY, window.maxY + 1)
        }
        panes.element(boundBy: 0).tap()
        XCTAssertTrue(panes.element(boundBy: 0).isSelected)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "phase7-ipad-split"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons.matching(identifier: "terminalUnsplit").firstMatch.tap()
        XCTAssertEqual(panes.count, 0)
      } else {
        XCTAssertTrue(app.buttons["importSSHConfig"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["terminalSplitMenu"].exists)
      }
      app.terminate()
    #else
      throw XCTSkip("iPhone/iPad native layout acceptance")
    #endif
  }

  func testSSHConfigFileSelectionPreviewAndImport() throws {
    #if os(macOS)
      continueAfterFailure = false
      let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        "ConnDock-UI-\(UUID()).config")
      try "Host imported-fixture\n HostName example.invalid\n User fixture\n Port 2222\n".write(
        to: file, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: file) }
      let app = XCUIApplication()
      app.launchEnvironment["CONNDOCK_UI_TESTING"] = "1"
      app.launchEnvironment["CONNDOCK_RESET_PREFERENCES"] = "1"
      app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      app.activate()
      let entry = app.buttons["importSSHConfig"]
      XCTAssertTrue(entry.waitForExistence(timeout: 8))
      entry.click()
      app.typeKey("g", modifierFlags: [.command, .shift])
      app.typeText(file.path)
      app.typeKey(.return, modifierFlags: [])
      app.typeKey(.return, modifierFlags: [])
      let save = app.buttons["sshConfigSaveSelected"]
      XCTAssertTrue(save.waitForExistence(timeout: 8))
      XCTAssertTrue(save.isEnabled)
      XCTAssertTrue(
        app.descendants(matching: .any)["sshConfigEntry.imported-fixture"].firstMatch.exists)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "phase7-ssh-config-preview"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      save.click()
      XCTAssertTrue(
        app.descendants(matching: .any)["sshConfigImportResult"].firstMatch.waitForExistence(
          timeout: 5))
      app.buttons["完成"].click()
      XCTAssertTrue(
        app.buttons.matching(
          NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "savedHost.",
            "imported-fixture")
        ).firstMatch.waitForExistence(timeout: 5))
      app.terminate()
    #else
      throw XCTSkip("macOS NSOpenPanel acceptance")
    #endif
  }

  func testSplitDirectionFocusAndJoin() throws {
    #if os(macOS)
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launchEnvironment["CONNDOCK_UI_TESTING"] = "1"
      app.launchEnvironment["CONNDOCK_RESET_PREFERENCES"] = "1"
      app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
      app.launch()
      app.activate()
      XCTAssertTrue(app.buttons["headerLocalTerminal"].waitForExistence(timeout: 8))
      app.buttons["headerLocalTerminal"].click()
      let terminals = app.textViews.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "terminalCanvas."))
      XCTAssertTrue(terminals.firstMatch.waitForExistence(timeout: 8))
      app.typeKey("d", modifierFlags: [.command])
      let panes = app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "terminalPaneFocus."))
      XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 5))
      XCTAssertEqual(panes.count, 2)
      XCTAssertEqual(terminals.count, 1)
      panes.element(boundBy: 0).click()
      XCTAssertTrue(panes.element(boundBy: 0).isSelected)
      panes.element(boundBy: 1).click()
      XCTAssertTrue(panes.element(boundBy: 1).isSelected)
      app.typeKey("d", modifierFlags: [.command, .shift])
      XCTAssertEqual(panes.count, 2)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "phase7-split-vertical"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      let join = app.buttons.matching(identifier: "terminalUnsplit").firstMatch
      XCTAssertTrue(join.exists)
      join.click()
      XCTAssertEqual(panes.count, 0)
      // Both terminal tabs survive joining; the local shell can be selected again.
      app.buttons["headerLocalTerminal"].click()
      XCTAssertEqual(terminals.count, 1)
      app.terminate()
    #else
      throw XCTSkip("macOS native keyboard and local PTY acceptance")
    #endif
  }
}
