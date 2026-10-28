#if os(iOS)
  import SwiftTerm
  import SwiftUI
  import UIKit
  import XCTest

  @testable import ConnDockKit

  @MainActor
  final class UIKitThemeTests: XCTestCase {
    func testPresentedSettingsSheetFollowsAppearanceWhileOpen() async throws {
      let domain = "ConnDock.SettingsThemeTests.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
      defer { defaults.removePersistentDomain(forName: domain) }
      let preferences = AppPreferences(defaults: defaults)
      preferences.appearance = .light
      let library = try HostLibrary(memoryOnly: true, cleanupDefaults: defaults)
      let workspace = WorkspaceState(library: library, trustDefaults: defaults)
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      let root = SettingsAppearanceHarness().environment(preferences).environment(workspace)
      let host = UIHostingController(rootView: root)
      window.rootViewController = host
      window.frame = scene.coordinateSpace.bounds
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      for _ in 0..<100 {
        if host.presentedViewController != nil { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let sheet = try XCTUnwrap(host.presentedViewController)
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(sheet.traitCollection.userInterfaceStyle, .light)
      preferences.appearance = .dark
      for _ in 0..<100 {
        if sheet.traitCollection.userInterfaceStyle == .dark { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(
        sheet.traitCollection.userInterfaceStyle, .dark,
        "An already open settings sheet must follow the changed app appearance")
      preferences.appearance = .light
      for _ in 0..<100 {
        if sheet.traitCollection.userInterfaceStyle == .light { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(sheet.traitCollection.userInterfaceStyle, .light)
    }

    func testSystemTraitsUpdateRealSwiftTermColors() async throws {
      let domain = "ConnDock.ThemeTests.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
      defer { defaults.removePersistentDomain(forName: domain) }
      let preferences = AppPreferences(defaults: defaults)
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
      let root = TerminalAppearanceHarness()
        .environment(preferences)
        .preferredColorScheme(preferences.appearance.colorScheme)
      window.rootViewController = UIHostingController(rootView: root)
      window.overrideUserInterfaceStyle = .light
      window.isHidden = false
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }

      let lightUpdated = try await waitForTerminalBackground((1, 1, 1), in: window)
      XCTAssertTrue(lightUpdated, "System light traits must reach the real SwiftTerm view")
      window.overrideUserInterfaceStyle = .dark
      let darkUpdated = try await waitForTerminalBackground(
        (24 / 255, 24 / 255, 37 / 255), in: window)
      XCTAssertTrue(darkUpdated, "System dark traits must reach the real SwiftTerm view")
      XCTAssertEqual(preferences.appearance, .system)
      XCTAssertEqual(preferences.terminalTheme, .followApp)
    }

    private func waitForTerminalBackground(
      _ expected: (CGFloat, CGFloat, CGFloat), in root: UIView
    ) async throws
      -> Bool
    {
      for _ in 0..<100 {
        if let terminal = terminal(in: root) {
          var red: CGFloat = 0
          var green: CGFloat = 0
          var blue: CGFloat = 0
          var alpha: CGFloat = 0
          if terminal.nativeBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            abs(red - expected.0) < 0.001, abs(green - expected.1) < 0.001,
            abs(blue - expected.2) < 0.001, alpha == 1
          {
            return true
          }
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      return false
    }

    private func terminal(in root: UIView) -> TerminalView? {
      if let terminal = root as? TerminalView { return terminal }
      for child in root.subviews {
        if let terminal = terminal(in: child) { return terminal }
      }
      return nil
    }
  }

  // The empty workspace shows onboarding; mount the real terminal directly for trait testing.
  private struct TerminalAppearanceHarness: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme

    var body: some View {
      NativeTerminalView(
        scheme: preferences.terminalTheme.resolvedScheme(appScheme: scheme),
        accessibilityText: preferences.text("terminal.nativeCanvas"), session: nil,
        fontSize: CGFloat(preferences.terminalFontSize))
    }
  }

  private struct SettingsAppearanceHarness: View {
    @Environment(AppPreferences.self) private var preferences
    var body: some View {
      Color.clear
        .sheet(isPresented: .constant(true)) { SettingsScreen() }
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
  }
#endif
