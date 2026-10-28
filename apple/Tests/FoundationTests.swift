import SSHCoreBridge
import SwiftUI
import XCTest

@testable import ConnDockKit

@MainActor
final class FoundationTests: XCTestCase {
  private func isolatedPreferences() -> (AppPreferences, UserDefaults, String) {
    let domain = "ConnDock.Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    return (AppPreferences(defaults: defaults), defaults, domain)
  }

  func testDefaultsAreChineseSystemAndFollowApp() {
    let (preferences, defaults, domain) = isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: domain) }
    XCTAssertEqual(preferences.language, .simplifiedChinese)
    XCTAssertEqual(preferences.appearance, .system)
    XCTAssertNil(preferences.appearance.colorScheme)
    XCTAssertEqual(preferences.terminalTheme, .followApp)
  }

  func testPreferencesPersistIndependentlyAcrossInstances() {
    let (preferences, defaults, domain) = isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: domain) }
    preferences.language = .english
    preferences.appearance = .dark
    preferences.terminalTheme = .light
    preferences.inspectorVisible = false
    preferences.sidebarWidth = 280
    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.language, .english)
    XCTAssertEqual(restored.appearance, .dark)
    XCTAssertEqual(restored.terminalTheme, .light)
    XCTAssertFalse(restored.inspectorVisible)
    XCTAssertEqual(restored.sidebarWidth, 280)
    restored.language = .simplifiedChinese
    XCTAssertEqual(restored.appearance, .dark)
    XCTAssertEqual(restored.terminalTheme, .light)
  }

  func testCorruptPreferencesFallBackToUsableDefaults() {
    let (_, defaults, domain) = isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set("invalid", forKey: "app.language")
    defaults.set("invalid", forKey: "app.appearance")
    defaults.set(-500, forKey: "layout.sidebarWidth")
    defaults.set(99999, forKey: "layout.filesHeight")
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.language, .simplifiedChinese)
    XCTAssertEqual(preferences.appearance, .system)
    XCTAssertEqual(preferences.sidebarWidth, 228)
    XCTAssertEqual(preferences.filesHeight, 230)
  }

  func testTerminalThemeResolvesWithoutChangingAppAppearance() {
    XCTAssertEqual(TerminalTheme.followApp.resolvedScheme(appScheme: .light), .light)
    XCTAssertEqual(TerminalTheme.followApp.resolvedScheme(appScheme: .dark), .dark)
    XCTAssertEqual(TerminalTheme.light.resolvedScheme(appScheme: .dark), .light)
    XCTAssertEqual(TerminalTheme.dark.resolvedScheme(appScheme: .light), .dark)
  }

  #if os(macOS)
    func testNativeTerminalExposesAnAccessibleInputSurface() {
      let session = TerminalSession(
        id: UUID(),
        target: ConnectionTarget(
          displayName: "", host: "example.invalid", port: 22, username: "tester",
          usesPrivateKey: false))
      let view = session.surface.view
      XCTAssertTrue(view.isAccessibilityElement())
      XCTAssertEqual(view.accessibilityRole(), .textArea)
      XCTAssertEqual(view.accessibilityIdentifier(), "sshTerminal")
      XCTAssertNil(
        view.accessibilityValue(), "Do not expose raw terminal contents through AX values")
      session.close()
    }
  #endif

  func testTerminalFontSizePersistsAndCorruptValuesFallBack() {
    let (preferences, defaults, domain) = isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: domain) }
    XCTAssertEqual(preferences.terminalFontSize, 13)
    preferences.terminalFontSize = 16
    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.terminalFontSize, 16)
    XCTAssertEqual(restored.appearance, .system)
    preferences.terminalFontSize = .nan
    XCTAssertEqual(preferences.terminalFontSize, 13)
    defaults.set(200, forKey: "terminal.fontSize")
    XCTAssertEqual(AppPreferences(defaults: defaults).terminalFontSize, 13)
  }

  func testLayoutResetDoesNotResetLanguageOrTheme() {
    let (preferences, defaults, domain) = isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: domain) }
    preferences.language = .english
    preferences.appearance = .dark
    preferences.sidebarVisible = false
    preferences.filesHeight = 400
    preferences.resetLayout()
    XCTAssertTrue(preferences.sidebarVisible)
    XCTAssertEqual(preferences.filesHeight, 230)
    XCTAssertEqual(preferences.language, .english)
    XCTAssertEqual(preferences.appearance, .dark)
  }

  func testClosingTabsSelectsNeighborAndNeverLeavesInvalidSelection() {
    let workspace = WorkspaceState()
    let welcomeID = workspace.selection
    workspace.addTerminal()
    let secondID = workspace.selection
    workspace.addTerminal()
    workspace.closeTab(secondID)
    XCTAssertEqual(workspace.tabs.count, 2)
    XCTAssertTrue(workspace.tabs.contains { $0.id == workspace.selection })
    workspace.closeTab(workspace.selection)
    XCTAssertEqual(workspace.selection, welcomeID)
    workspace.closeTab(welcomeID)
    XCTAssertEqual(workspace.tabs.count, 1)
    XCTAssertTrue(workspace.tabs[0].isWelcome)
    XCTAssertEqual(workspace.selection, workspace.tabs[0].id)
  }

  func testLocalizationSwitchUsesActualCompiledCatalog() {
    XCTAssertEqual(L10n.text("settings.title", language: .simplifiedChinese), "设置")
    XCTAssertEqual(L10n.text("settings.title", language: .english), "Settings")
    XCTAssertEqual(L10n.text("terminal.disconnected", language: .english), "Not Connected")
    XCTAssertEqual(L10n.text("action.newHost", language: .simplifiedChinese), "新建连接")
    XCTAssertEqual(L10n.text("language.chinese", language: .english), "简体中文")
  }

  func testActualRustBridgeReturnsExpectedContract() async {
    let info = await BridgeProbe.shared.readInfo()
    XCTAssertEqual(info.version, "0.1.0")
    XCTAssertEqual(info.bridgeProtocol, 2)
    XCTAssertTrue(info.networkEnabled)
  }
}
