import XCTest

#if os(iOS)
  import UIKit
#endif

@MainActor
final class AdvancedConnectionUITests: XCTestCase {
  func testFilesModeAndMFAOptionsPersistAcrossEditing() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CONNDOCK_UI_TESTING"] = "1"
    app.launchEnvironment["CONNDOCK_RESET_PREFERENCES"] = "1"
    #if os(iOS)
      XCUIDevice.shared.orientation =
        UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    #else
      app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    #endif
    app.launch()
    let sidebar = app.buttons["sidebarNewHost"]
    let phone = app.buttons["phoneNewHost"]
    if sidebar.waitForExistence(timeout: 3) {
      press(sidebar)
    } else {
      XCTAssertTrue(phone.waitForExistence(timeout: 5))
      press(phone)
    }
    let files = app.descendants(matching: .any)["connectionFilesOnly"].firstMatch
    let mfa = app.descendants(matching: .any)["connectionAllowInteractive"].firstMatch
    XCTAssertTrue(files.waitForExistence(timeout: 5))
    turnOn(files, in: app)
    turnOn(mfa, in: app)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "phase8-connection-options"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    #if os(iOS)
      if !app.textFields["connectionName"].exists {
        let form = app.collectionViews.firstMatch
        form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(
          forDuration: 0.05,
          thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
      }
    #endif
    fill(app.textFields["connectionName"], "Phase8")
    fill(app.textFields["connectionHost"], "example.invalid")
    fill(app.textFields["connectionUsername"], "fixture")
    let save = app.buttons["connectionSave"]
    XCTAssertTrue(save.isEnabled)
    press(save)
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "savedHost.", "Phase8")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    #if os(macOS)
      row.doubleClick()
    #else
      row.tap()
    #endif
    XCTAssertTrue(files.waitForExistence(timeout: 5))
    XCTAssertEqual(String(describing: files.value ?? ""), "1")
    XCTAssertEqual(String(describing: mfa.value ?? ""), "1")
    app.terminate()
  }

  private func press(_ element: XCUIElement) {
    #if os(macOS)
      element.click()
    #else
      element.tap()
    #endif
  }
  private func turnOn(_ element: XCUIElement, in app: XCUIApplication) {
    #if os(macOS)
      press(element)
    #else
      // A row may extend below the iPad sheet's viewport. A coordinate tap
      // there dismisses the sheet; first scroll within the actual Form.
      let form = app.collectionViews.containing(.switch, identifier: element.identifier).firstMatch
      XCTAssertTrue(form.exists)
      let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
      if !form.frame.insetBy(dx: 0, dy: 24).contains(center) {
        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(
          forDuration: 0.05,
          thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
      }
      element.descendants(matching: .switch).firstMatch.tap()
    #endif
    XCTAssertEqual(String(describing: element.value ?? ""), "1")
  }
  private func fill(_ element: XCUIElement, _ value: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    press(element)
    element.typeText(value)
  }
}
