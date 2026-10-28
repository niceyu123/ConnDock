import XCTest

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class PhaseZeroUITests: XCTestCase {
  private let app = XCUIApplication()
  private var originalDeviceAppearance: XCUIDevice.Appearance?

  override func tearDown() {
    if let originalDeviceAppearance { XCUIDevice.shared.appearance = originalDeviceAppearance }
    super.tearDown()
  }

  private var platformName: String {
    #if os(macOS)
      "macos"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    #endif
  }

  private func launch(reset: Bool) {
    continueAfterFailure = false
    app.launchEnvironment["CONNDOCK_UI_TESTING"] = "1"
    app.launchEnvironment["CONNDOCK_RESET_PREFERENCES"] = reset ? "1" : "0"
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    #if os(macOS)
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    #else
      XCUIDevice.shared.orientation = platformName == "ipad" ? .landscapeLeft : .portrait
    #endif
    app.launch()
    app.activate()
    #if os(macOS)
      placeWindowOnPrimaryDisplay()
    #endif
  }

  #if os(macOS)
    private func placeWindowOnPrimaryDisplay() {
      let window = app.windows["workspace"]
      XCTAssertTrue(window.waitForExistence(timeout: 5))
      guard let screen = NSScreen.screens.first else { return XCTFail("No desktop display") }
      let frame = window.frame
      let visible = screen.visibleFrame
      let targetX = visible.minX + max(0, (visible.width - frame.width) / 2)
      // AX screen coordinates start at the top; AppKit screen coordinates at the bottom.
      let targetY = screen.frame.maxY - visible.maxY + max(0, (visible.height - frame.height) / 2)
      guard abs(frame.minX - targetX) > 2 || abs(frame.minY - targetY) > 2 else { return }
      let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.01))
      title.click(
        forDuration: 0.1,
        thenDragTo: title.withOffset(CGVector(dx: targetX - frame.minX, dy: targetY - frame.minY)))
      // AppKit may adjust the titlebar position. The acceptance condition is
      // that the complete window is on this display, not an exact center pixel.
      XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX)
      XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX)
      XCTAssertGreaterThanOrEqual(window.frame.minY, screen.frame.maxY - visible.maxY)
      XCTAssertLessThanOrEqual(window.frame.maxY, screen.frame.maxY - visible.minY)
    }
  #endif

  private func openSettings(chinese: Bool) {
    #if os(macOS)
      app.buttons["openSettings"].click()
    #else
      if platformName == "ipad" {
        app.buttons["tabletSettings"].tap()
      } else {
        app.tabBars.buttons[chinese ? "设置" : "Settings"].tap()
      }
    #endif
    showSettingsCategory("general")
    XCTAssertTrue(
      app.descendants(matching: .any)["languagePicker"].firstMatch.waitForExistence(timeout: 5))
  }

  private func showSettingsCategory(_ category: String) {
    let item = app.descendants(matching: .any)["settingsCategory.\(category)"].firstMatch
    #if os(iOS)
      if !item.exists {
        let back = app.navigationBars.buttons.matching(
          NSPredicate(format: "label IN %@", ["设置", "Settings"])
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
      }
    #endif
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    press(item)
  }

  private func press(_ element: XCUIElement) {
    #if os(macOS)
      app.activate()
      element.click()
    #else
      element.tap()
    #endif
  }

  private func visibleText(_ value: String) -> XCUIElement {
    // AppKit exposes combined SwiftUI text as an AX group/value, whereas UIKit
    // generally exposes individual static-text labels.
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
    ).firstMatch
  }

  private func choose(_ picker: String, _ title: String) {
    showSettingsCategory(picker == "languagePicker" ? "general" : "appearance")
    #if os(macOS)
      press(app.radioButtons[title])
    #else
      press(app.segmentedControls[picker].buttons[title])
    #endif
  }

  private func closeSettings(chinese: Bool) {
    #if os(macOS)
      app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()
    #else
      if platformName == "ipad" {
        app.buttons["closeSettings"].tap()
      } else {
        app.tabBars.buttons[chinese ? "服务器" : "Servers"].tap()
      }
    #endif
  }

  private func capture(_ name: String) {
    // Functional UI checks can run when the desktop screenshot service is
    // unavailable. Keep that limitation separate from the persistence result.
    guard ProcessInfo.processInfo.environment["CONNDOCK_UI_CAPTURE_SCREENSHOTS"] != "0" else {
      return
    }
    let screenshot: XCUIScreenshot
    #if os(macOS)
      let settings = app.windows["com_apple_SwiftUI_Settings_window"]
      screenshot = (settings.exists ? settings : app.windows["workspace"]).screenshot()
    #else
      screenshot = XCUIScreen.main.screenshot()
    #endif
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(platformName)-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testPrivacyVersionAndBackgroundRecovery() {
    launch(reset: true)
    openSettings(chinese: true)
    choose("appearancePicker", "浅色")
    showSettingsCategory("security")
    XCTAssertTrue(visibleText("应用遥测").waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["privacyLocalData"].firstMatch.exists)
    capture("phase6-privacy-zh-light")
    showSettingsCategory("about")
    XCTAssertTrue(visibleText("ConnDock").waitForExistence(timeout: 5))
    XCTAssertTrue(visibleText("0.1.0 (1)").waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@ OR value == %@", "0.1.0", "0.1.0")
      ).firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(visibleText("Local 本机验证").exists)
    choose("languagePicker", "English")
    choose("appearancePicker", "Dark")
    showSettingsCategory("security")
    XCTAssertTrue(visibleText("App telemetry").waitForExistence(timeout: 5))
    capture("phase6-privacy-en-dark")
    closeSettings(chinese: false)
    #if os(iOS)
      XCUIDevice.shared.press(.home)
      XCTAssertTrue(
        app.wait(for: .runningBackground, timeout: 2) || app.state == .runningBackgroundSuspended)
      app.activate()
    #endif
    app.terminate()
    launch(reset: false)
    openSettings(chinese: false)
    #if os(macOS)
      XCTAssertEqual(String(describing: app.radioButtons["English"].value ?? ""), "1")
    #else
      XCTAssertTrue(app.segmentedControls["languagePicker"].buttons["English"].isSelected)
    #endif
    showSettingsCategory("security")
    XCTAssertTrue(visibleText("App telemetry").waitForExistence(timeout: 5))
    showSettingsCategory("about")
    XCTAssertTrue(visibleText("0.1.0 (1)").exists)
    XCTAssertTrue(visibleText("Local verification").exists)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@ OR value == %@", "0.1.0", "0.1.0")
      ).firstMatch.waitForExistence(timeout: 5))
    capture("phase6-about-en-dark")
  }

  #if os(macOS)
    func testMCPSettingsPermissionsAndLocalizedAppearance() {
      launch(reset: true)
      openSettings(chinese: true)
      choose("appearancePicker", "浅色")
      showSettingsCategory("mcp")
      let enabled = app.descendants(matching: .any)["mcpEnabled"].firstMatch
      XCTAssertTrue(enabled.waitForExistence(timeout: 5))
      XCTAssertEqual(String(describing: enabled.value ?? ""), "0")
      XCTAssertTrue(visibleText("先添加主机").exists)
      press(enabled)
      let confirm = app.windows["com_apple_SwiftUI_Settings_window"].sheets.buttons["启用并配置权限"]
        .firstMatch
      XCTAssertTrue(confirm.waitForExistence(timeout: 5))
      press(confirm)
      XCTAssertEqual(String(describing: enabled.value ?? ""), "1")
      let test = app.buttons["mcpTestConnection"]
      XCTAssertTrue(test.waitForExistence(timeout: 5))
      press(test)
      XCTAssertTrue(visibleText("已通过签名 helper").waitForExistence(timeout: 10))
      capture("phase5-zh-light-mcp")
      choose("languagePicker", "English")
      choose("appearancePicker", "Dark")
      showSettingsCategory("mcp")
      XCTAssertTrue(visibleText("Enable MCP").waitForExistence(timeout: 5))
      capture("phase5-en-dark-mcp")
      press(enabled)
      XCTAssertEqual(String(describing: enabled.value ?? ""), "0")
      app.terminate()
      launch(reset: false)
      openSettings(chinese: false)
      showSettingsCategory("mcp")
      XCTAssertEqual(
        String(describing: app.descendants(matching: .any)["mcpEnabled"].firstMatch.value ?? ""),
        "0")
    }
  #endif

  func testLanguageAppearancePersistenceAndScreenshots() {
    launch(reset: true)
    #if os(macOS)
      XCTAssertTrue(app.buttons["sidebarNewHost"].waitForExistence(timeout: 5))
      XCTAssertTrue(visibleText("未连接").exists)
    #else
      XCTAssertTrue(app.staticTexts["服务器"].firstMatch.waitForExistence(timeout: 5))
    #endif
    openSettings(chinese: true)
    choose("appearancePicker", "浅色")
    showSettingsCategory("general")
    capture("zh-light-settings")
    choose("languagePicker", "English")
    XCTAssertTrue(visibleText("General").waitForExistence(timeout: 5))
    choose("appearancePicker", "Dark")
    capture("en-dark-settings")
    closeSettings(chinese: false)
    capture("en-dark-workspace")
    #if os(macOS)
      XCTAssertTrue(visibleText("Not Connected").exists)
      XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.exists)
      app.menuBars.menuBarItems["Layout"].click()
      XCTAssertTrue(app.menuItems["Reset Layout"].exists)
      app.typeKey(.escape, modifierFlags: [])
    #endif

    app.terminate()
    launch(reset: false)
    #if os(macOS)
      XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.exists)
    #else
      if platformName == "iphone" { app.tabBars.buttons["Terminal"].tap() }
      XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.exists)
    #endif
    openSettings(chinese: false)
    XCTAssertTrue(visibleText("General").exists)
    choose("appearancePicker", "System")
    choose("appearancePicker", "Light")
    choose("languagePicker", "简体中文")
    XCTAssertTrue(visibleText("通用").waitForExistence(timeout: 5))
    closeSettings(chinese: true)
    capture("zh-light-workspace")
    #if os(iOS)
      if platformName == "iphone" {
        app.tabBars.buttons["终端"].tap()
        XCTAssertTrue(visibleText("未连接").exists)
        capture("zh-light-terminal")
        app.buttons["openFiles"].tap()
        XCTAssertTrue(visibleText("还没有远程文件").waitForExistence(timeout: 5))
        capture("zh-light-files")
        app.buttons["完成"].tap()
      }
    #endif
  }

  func testCloudSyncSettingsStayLocalWithoutSigningAndSupportBothThemes() {
    launch(reset: true)
    openSettings(chinese: true)
    choose("appearancePicker", "浅色")
    showSettingsCategory("iCloud")
    let toggle = app.descendants(matching: .any)["cloudSyncToggle"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertFalse(toggle.isEnabled)
    XCTAssertTrue(visibleText("密码和私钥").exists)
    capture("phase4-zh-light-cloud-settings")
    choose("languagePicker", "English")
    choose("appearancePicker", "Dark")
    showSettingsCategory("iCloud")
    XCTAssertTrue(visibleText("Passwords and private keys").waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["cloudSyncToggle"].firstMatch.isEnabled)
    capture("phase4-en-dark-cloud-settings")
    closeSettings(chinese: false)
  }

  func testNavigationDoesNotCreateFakeConnections() {
    launch(reset: true)
    #if os(macOS)
      app.buttons["newTerminalTab"].click()
      app.buttons["newTerminalTab"].click()
      XCTAssertTrue(visibleText("未连接").exists)
      let groups = app.buttons["hostGroupsDisclosure"]
      press(groups)
      press(app.buttons["newHostGroup"])
      XCTAssertTrue(app.textFields["groupName"].waitForExistence(timeout: 5))
      press(app.buttons["取消"])
      press(groups)
      app.buttons["sidebarNewHost"].click()
    #else
      if platformName == "ipad" {
        app.buttons["sidebarNewHost"].tap()
      } else {
        app.buttons["phoneNewHost"].tap()
      }
    #endif
    XCTAssertTrue(app.buttons["connectionConnect"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["connectionConnect"].isEnabled)
    press(app.buttons["取消"])
  }

  func testSavedConfigurationPersistsWithoutConnecting() {
    launch(reset: true)
    openSettings(chinese: true)
    choose("appearancePicker", "浅色")
    closeSettings(chinese: true)
    openNewGroup(chinese: true)
    let groupName = app.textFields["groupName"]
    XCTAssertTrue(groupName.waitForExistence(timeout: 5))
    press(groupName)
    groupName.typeText("Persistence Group")
    capture("phase2-zh-light-group-form")
    press(app.buttons["groupSave"])
    #if os(macOS)
      press(app.buttons["sidebarNewHost"])
    #else
      press(app.buttons[platformName == "ipad" ? "sidebarNewHost" : "phoneNewHost"])
    #endif
    for (identifier, value) in [
      ("connectionName", "Persistence Validation"),
      ("connectionHost", "example.invalid"),
      ("connectionUsername", "tester"),
    ] {
      let field = app.textFields[identifier]
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      press(field)
      field.typeText(value)
    }
    if ProcessInfo.processInfo.environment["CONNDOCK_UI_DIAGNOSTICS"] == "1" {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "SavedHostForm-Accessibility"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertFalse(app.buttons["connectionConnect"].isEnabled)
    XCTAssertTrue(app.buttons["connectionSave"].isEnabled)
    capture("phase2-zh-light-host-form")
    press(app.buttons["connectionSave"])
    XCTAssertTrue(visibleText("Persistence Validation").waitForExistence(timeout: 5))
    capture("phase2-zh-light-saved-hosts")
    app.terminate()
    launch(reset: false)
    XCTAssertTrue(visibleText("Persistence Validation").waitForExistence(timeout: 5))
    XCTAssertTrue(visibleText("tester@example.invalid:22").exists)
    openSettings(chinese: true)
    choose("languagePicker", "English")
    choose("appearancePicker", "Dark")
    closeSettings(chinese: false)
    XCTAssertTrue(visibleText("Persistence Validation").exists)
    capture("phase2-en-dark-saved-hosts")
    #if os(macOS)
      press(app.buttons["sidebarNewHost"])
    #else
      press(app.buttons[platformName == "ipad" ? "sidebarNewHost" : "phoneNewHost"])
    #endif
    XCTAssertTrue(app.buttons["connectionSave"].waitForExistence(timeout: 5))
    capture("phase2-en-dark-host-form")
    press(app.buttons["Cancel"])
    openNewGroup(chinese: false)
    XCTAssertTrue(app.textFields["groupName"].waitForExistence(timeout: 5))
    capture("phase2-en-dark-group-form")
    press(app.buttons["Cancel"])
  }

  private func openNewGroup(chinese: Bool) {
    #if os(iOS)
      if platformName == "iphone" {
        press(app.buttons["phoneGroups"])
        press(app.buttons[chinese ? "新建分组" : "New Group"])
        return
      }
    #endif
    press(app.buttons["newHostGroup"])
  }

  func testSystemAppearanceFollowsDevice() {
    originalDeviceAppearance = XCUIDevice.shared.appearance
    XCUIDevice.shared.appearance = .light
    launch(reset: true)
    #if os(iOS)
      if platformName == "iphone" { app.tabBars.buttons["终端"].tap() }
    #endif
    XCTAssertTrue(
      app.descendants(matching: .any)["terminalCanvas.light"].firstMatch.waitForExistence(
        timeout: 5))
    capture("zh-system-light-workspace")
    XCUIDevice.shared.appearance = .dark
    XCTAssertTrue(
      app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.waitForExistence(timeout: 5)
    )
    capture("zh-system-dark-workspace")
  }

  func testIndependentTerminalThemePersists() {
    launch(reset: true)
    openSettings(chinese: true)
    choose("appearancePicker", "浅色")
    showSettingsCategory("terminal")
    press(app.descendants(matching: .any)["terminalThemePicker"].firstMatch)
    #if os(macOS)
      app.menuItems["深色终端"].click()
    #else
      app.buttons["深色终端"].tap()
    #endif
    closeSettings(chinese: true)
    #if os(iOS)
      if platformName == "iphone" { app.tabBars.buttons["终端"].tap() }
    #endif
    XCTAssertTrue(
      app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.waitForExistence(timeout: 5)
    )
    capture("zh-light-dark-terminal")
    app.terminate()
    launch(reset: false)
    #if os(iOS)
      if platformName == "iphone" { app.tabBars.buttons["终端"].tap() }
    #endif
    XCTAssertTrue(
      app.descendants(matching: .any)["terminalCanvas.dark"].firstMatch.waitForExistence(timeout: 5)
    )
    openSettings(chinese: true)
    showSettingsCategory("terminal")
    press(app.descendants(matching: .any)["terminalThemePicker"].firstMatch)
    #if os(macOS)
      app.menuItems["跟随应用"].click()
    #else
      app.buttons["跟随应用"].tap()
    #endif
    closeSettings(chinese: true)
    #if os(iOS)
      if platformName == "iphone" { app.tabBars.buttons["终端"].tap() }
    #endif
    XCTAssertTrue(
      app.descendants(matching: .any)["terminalCanvas.light"].firstMatch.waitForExistence(
        timeout: 5))
  }

  #if os(macOS)
    private struct SSHUIConfiguration: Decodable {
      let host: String
      let port: UInt16
      let username: String
      let fingerprint: String
      let privateKeyPath: String
      let workingDirectory: String
      let phase: String?
      let expectLinux: Bool?
      let uploadFilePath: String?
      let exportDirectoryPath: String?
    }

    func testRealSSHConnectionFormAndScreenshots() throws {
      guard let path = ProcessInfo.processInfo.environment["CONNDOCK_UI_SSH_CONFIGURATION"] else {
        throw XCTSkip("Run scripts/test-local-ssh.sh --apple-only with the UI SSH method")
      }
      let url = URL(fileURLWithPath: path)
      let configuration = try JSONDecoder().decode(
        SSHUIConfiguration.self, from: Data(contentsOf: url))
      let phase = configuration.phase ?? "phase2"
      // Xcode's UI runner can read external files but cannot delete them.
      // This input contains only paths/metadata; its owning script removes it
      // after the run. Private-key bytes are imported through NSOpenPanel.
      // This opt-in UI fixture may only operate on the isolated loopback sshd.
      guard configuration.host == "127.0.0.1", configuration.port > 0,
        FileManager.default.fileExists(atPath: configuration.privateKeyPath),
        FileManager.default.fileExists(atPath: configuration.workingDirectory)
      else { throw SSHUIError.invalidConfiguration }
      launch(reset: true)
      openSettings(chinese: true)
      choose("appearancePicker", "浅色")
      closeSettings(chinese: true)
      press(app.buttons["sidebarNewHost"])
      for (identifier, value) in [
        ("connectionName", "OpenSSH UI Validation"), ("connectionHost", configuration.host),
        ("connectionPort", String(configuration.port)),
        ("connectionUsername", configuration.username),
      ] {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        press(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
      }
      press(app.popUpButtons["connectionAuthentication"])
      press(app.menuItems["SSH 密钥"])
      press(app.buttons["importPrivateKey"])
      app.typeKey("g", modifierFlags: [.command, .shift])
      app.typeText(configuration.privateKeyPath)
      app.typeKey(.return, modifierFlags: [])
      let open = app.buttons["OKButton"]
      XCTAssertTrue(open.waitForExistence(timeout: 5))
      press(open)
      let connect = app.buttons["connectionConnect"]
      XCTAssertTrue(connect.waitForExistence(timeout: 5))
      let imported = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in !open.exists && connect.isEnabled }, object: nil)
      let importResult = XCTWaiter.wait(for: [imported], timeout: 10)
      if importResult != .completed {
        let importError = app.descendants(matching: .any)["connectionError"].firstMatch
        let diagnostic = XCTAttachment(
          string:
            "panelOpen=\(open.exists), connectEnabled=\(connect.isEnabled), "
            + "host=\(app.textFields["connectionHost"].value ?? ""), "
            + "port=\(app.textFields["connectionPort"].value ?? ""), "
            + "username=\(app.textFields["connectionUsername"].value ?? ""), "
            + "importError=\(importError.exists ? importError.label : "none")")
        diagnostic.name = "PrivateKeyImport-State"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
      }
      XCTAssertEqual(importResult, .completed)
      capture("\(phase)-zh-light-key-form")
      press(connect)
      let fingerprint = app.descendants(matching: .any)["hostKeyFingerprint"].firstMatch
      XCTAssertTrue(fingerprint.waitForExistence(timeout: 10))
      XCTAssertTrue(
        fingerprint.label.contains(configuration.fingerprint)
          || (fingerprint.value as? String)?.contains(configuration.fingerprint) == true,
        "Trust must match the independently generated OpenSSH host key")
      capture("\(phase)-zh-light-host-trust")
      press(app.buttons["trustHostKey"])
      XCTAssertTrue(visibleText("已连接").waitForExistence(timeout: 10))
      sendSSHUICommand(configuration: configuration, scheme: "light", marker: "ui-light-ready")
      if phase == "phase3" { try validateRemoteServicesUI(configuration) }
      capture("\(phase)-zh-light-ssh-ui")
      openSettings(chinese: true)
      choose("languagePicker", "English")
      choose("appearancePicker", "Dark")
      closeSettings(chinese: false)
      XCTAssertTrue(visibleText("Connected").waitForExistence(timeout: 5))
      sendSSHUICommand(configuration: configuration, scheme: "dark", marker: "ui-dark-ready")
      capture("\(phase)-en-dark-ssh-ui")
      press(app.buttons["terminalDisconnect"])
      XCTAssertTrue(visibleText("Disconnected").waitForExistence(timeout: 10))
    }

    private func validateRemoteServicesUI(_ configuration: SSHUIConfiguration) throws {
      guard let sourcePath = configuration.uploadFilePath,
        let exportDirectory = configuration.exportDirectoryPath
      else {
        throw SSHUIError.invalidConfiguration
      }
      let divider = app.descendants(matching: .any)["layout.resizeFiles"].firstMatch
      let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
      let link = app.descendants(matching: .any)["sftp.entry.ConnDock-Test"].firstMatch
      XCTAssertTrue(link.waitForExistence(timeout: 10))
      link.doubleClick()
      let currentPath = app.descendants(matching: .any)["sftp.currentPath"].firstMatch
      waitForUI {
        currentPath.exists
          && (currentPath.label == configuration.workingDirectory
            || (currentPath.value as? String) == configuration.workingDirectory)
      }
      if configuration.expectLinux != false {
        XCTAssertTrue(
          app.descendants(matching: .any)["monitor.value.cpu"].firstMatch.waitForExistence(
            timeout: 15))
      } else {
        XCTAssertTrue(
          app.descendants(matching: .any)["monitor.error"].firstMatch.waitForExistence(timeout: 15))
      }
      press(app.buttons["sftp.newDirectory"])
      let name = app.textFields["sftp.nameField"]
      XCTAssertTrue(name.waitForExistence(timeout: 5))
      name.typeText("UI-目录验收")
      XCTAssertEqual(name.value as? String, "UI-目录验收")
      capture("phase3-zh-light-directory-form")
      press(app.buttons["保存"])
      let remoteFolder = URL(fileURLWithPath: configuration.workingDirectory)
        .appendingPathComponent("UI-目录验收")
      waitForUI { FileManager.default.fileExists(atPath: remoteFolder.path) }
      press(app.buttons["sftp.upload"])
      app.typeKey("g", modifierFlags: [.command, .shift])
      app.typeText(sourcePath)
      app.typeKey(.return, modifierFlags: [])
      let open = app.buttons["OKButton"]
      XCTAssertTrue(open.waitForExistence(timeout: 5))
      press(open)
      let nameOnServer = URL(fileURLWithPath: sourcePath).lastPathComponent
      let uploaded = app.descendants(matching: .any)["sftp.entry.\(nameOnServer)"].firstMatch
      XCTAssertTrue(uploaded.waitForExistence(timeout: 15))
      XCTAssertTrue(app.buttons["sftp.showTransfers"].exists)
      // Delete only the disposable fixture's upload, then re-create it by a real
      // Finder drag. This verifies file URL delivery and sandbox access together.
      uploaded.rightClick()
      press(app.menuItems["删除"].firstMatch)
      let deleteUpload = app.windows.descendants(matching: .button).matching(
        NSPredicate(format: "label == %@", "删除")
      ).firstMatch
      XCTAssertTrue(deleteUpload.waitForExistence(timeout: 5))
      press(deleteUpload)
      let remoteUpload = URL(fileURLWithPath: configuration.workingDirectory)
        .appendingPathComponent(nameOnServer)
      waitForUI { !FileManager.default.fileExists(atPath: remoteUpload.path) }
      try dragFileFromFinder(URL(fileURLWithPath: sourcePath))
      XCTAssertTrue(uploaded.waitForExistence(timeout: 15))
      XCTAssertEqual(
        try Data(contentsOf: remoteUpload), try Data(contentsOf: URL(fileURLWithPath: sourcePath)))
      capture("sftp-zh-light-drop-upload")
      press(uploaded)
      press(app.buttons["sftp.download"])
      XCTAssertTrue(app.buttons["sftp.showTransfers"].exists)
      press(app.buttons["sftp.tab.transfers"])
      let save = app.buttons["sftp.saveLocal"]
      XCTAssertTrue(save.waitForExistence(timeout: 15))
      press(save)
      app.typeKey("g", modifierFlags: [.command, .shift])
      app.typeText(exportDirectory)
      app.typeKey(.return, modifierFlags: [])
      let confirm = app.buttons["OKButton"]
      XCTAssertTrue(confirm.waitForExistence(timeout: 5))
      press(confirm)
      let exported = URL(fileURLWithPath: exportDirectory).appendingPathComponent(nameOnServer)
      waitForUI { FileManager.default.fileExists(atPath: exported.path) }
      XCTAssertEqual(
        try Data(contentsOf: exported), try Data(contentsOf: URL(fileURLWithPath: sourcePath)))
      press(app.buttons["sftp.tab.files"])
      let folder = app.descendants(matching: .any)["sftp.entry.UI-目录验收"].firstMatch
      XCTAssertTrue(folder.waitForExistence(timeout: 5))
      folder.rightClick()
      press(app.menuItems["删除"].firstMatch)
      // Touch Bar mirrors may share the title but cannot receive mouse events.
      let deleteConfirmation = app.windows.descendants(matching: .button).matching(
        NSPredicate(format: "label == %@", "删除")
      ).firstMatch
      XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 5))
      press(deleteConfirmation)
      waitForUI { !FileManager.default.fileExists(atPath: remoteFolder.path) }
    }

    private func dragFileFromFinder(_ url: URL) throws {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
      finder.activate()
      let window = finder.windows.firstMatch
      XCTAssertTrue(window.waitForExistence(timeout: 5))
      if let screen = NSScreen.screens.first {
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.01))
        let right = screen.frame.maxX - window.frame.width - 10
        title.click(
          forDuration: 0.1,
          thenDragTo: title.withOffset(CGVector(dx: right - window.frame.minX, dy: 0)))
      }
      let file = window.descendants(matching: .any).matching(
        NSPredicate(
          format: "label == %@ OR value == %@ OR label == %@ OR value == %@",
          url.lastPathComponent, url.lastPathComponent,
          url.deletingPathExtension().lastPathComponent,
          url.deletingPathExtension().lastPathComponent)
      ).firstMatch
      XCTAssertTrue(file.waitForExistence(timeout: 5))
      let target = app.descendants(matching: .any)["sftp.directoryList"].firstMatch
      XCTAssertTrue(target.exists)
      file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
        forDuration: 0.2,
        thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)))
      app.activate()
    }

    private func waitForUI(_ condition: @escaping () -> Bool) {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in condition() }, object: nil)
      let result = XCTWaiter.wait(for: [expectation], timeout: 15)
      if result != .completed {
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = "RemoteServices-AX-Diagnostic"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        capture("phase3-diagnostic")
      }
      XCTAssertEqual(result, .completed)
    }

    private func sendSSHUICommand(configuration: SSHUIConfiguration, scheme: String, marker: String)
    {
      // SwiftUI folds the native view into the canvas and supplies its final AX identifier.
      let canvas = app.textViews["terminalCanvas.\(scheme)"]
      XCTAssertTrue(canvas.waitForExistence(timeout: 5))
      XCTAssertTrue(canvas.isEnabled)
      press(canvas)
      let directory = configuration.workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
      // The marker is written by the remote shell on the loopback SSH service,
      // proving that keyboard input traversed the actual UI/PTY/network path.
      app.typeText(
        "stty -echo; cd '\(directory)'; printf '\\033[32mConnDock \\344\\270\\255\\346\\226\\207 \\360\\237\\231\\202\\033[0m\\n'; pwd; ls -la; touch '\(marker)'\n"
      )
      let markerPath = URL(fileURLWithPath: configuration.workingDirectory).appendingPathComponent(
        marker
      ).path
      let executed = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          FileManager.default.fileExists(atPath: markerPath)
        }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [executed], timeout: 10), .completed)
    }

    private enum SSHUIError: Error { case invalidConfiguration }

    func testLayoutResizeAndVisibilityPersist() {
      launch(reset: true)
      let divider = app.descendants(matching: .any)["layout.resizeSidebar"].firstMatch
      XCTAssertTrue(divider.waitForExistence(timeout: 5))
      let before = divider.frame.minX
      let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      // press(forDuration:) synthesizes touch events, even when it compiles on macOS.
      start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 0)))
      XCTAssertGreaterThan(divider.frame.minX, before + 20)
      let sidebarWidth = divider.value as? String
      let inspector = app.descendants(matching: .any)["layout.resizeInspector"].firstMatch
      let inspectorBefore = inspector.frame.minX
      let inspectorStart = inspector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      inspectorStart.click(
        forDuration: 0.1, thenDragTo: inspectorStart.withOffset(CGVector(dx: -30, dy: 0)))
      XCTAssertLessThan(inspector.frame.minX, inspectorBefore - 15)
      let inspectorWidth = inspector.value as? String
      let files = app.descendants(matching: .any)["layout.resizeFiles"].firstMatch
      let filesBefore = files.frame.minY
      let filesStart = files.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      filesStart.click(
        forDuration: 0.1, thenDragTo: filesStart.withOffset(CGVector(dx: 0, dy: -30)))
      XCTAssertLessThan(files.frame.minY, filesBefore - 15)
      let filesHeight = files.value as? String
      press(app.buttons["sftp.togglePanel"])
      XCTAssertFalse(visibleText("还没有远程文件").exists)
      app.terminate()
      launch(reset: false)
      XCTAssertFalse(visibleText("还没有远程文件").exists)
      XCTAssertEqual(
        app.descendants(matching: .any)["layout.resizeSidebar"].firstMatch.value as? String,
        sidebarWidth)
      XCTAssertEqual(
        app.descendants(matching: .any)["layout.resizeInspector"].firstMatch.value as? String,
        inspectorWidth)
      press(app.buttons["sftp.togglePanel"])
      XCTAssertEqual(
        app.descendants(matching: .any)["layout.resizeFiles"].firstMatch.value as? String,
        filesHeight)
      app.menuBars.menuBarItems["布局"].click()
      app.menuItems["恢复默认布局"].click()
      XCTAssertTrue(visibleText("还没有远程文件").waitForExistence(timeout: 5))
    }
  #endif
}
