import Foundation
import Observation
import SwiftUI

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system, light, dark
  public var id: String { rawValue }
  public var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
  var titleKey: String { "appearance.\(rawValue)" }
}

public enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
  case followApp, light, dark
  public var id: String { rawValue }
  var titleKey: String { "terminalTheme.\(rawValue)" }
  public func resolvedScheme(appScheme: ColorScheme) -> ColorScheme {
    switch self {
    case .followApp: appScheme
    case .light: .light
    case .dark: .dark
    }
  }
}

@MainActor @Observable
public final class AppPreferences {
  @ObservationIgnored private let defaults: UserDefaults
  let remoteBookmarks: RemoteBookmarkStore
  public var language: AppLanguage {
    didSet { defaults.set(language.rawValue, forKey: "app.language") }
  }
  public var appearance: AppAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: "app.appearance") }
  }
  public var terminalTheme: TerminalTheme {
    didSet { defaults.set(terminalTheme.rawValue, forKey: "terminal.theme") }
  }
  private var storedTerminalFontSize: Double
  public var terminalFontSize: Double {
    get { storedTerminalFontSize }
    set {
      storedTerminalFontSize = Self.dimension(newValue, fallback: 13, range: 10...24)
      defaults.set(storedTerminalFontSize, forKey: "terminal.fontSize")
    }
  }
  public var sidebarVisible: Bool {
    didSet { defaults.set(sidebarVisible, forKey: "layout.sidebarVisible") }
  }
  public var inspectorVisible: Bool {
    didSet { defaults.set(inspectorVisible, forKey: "layout.inspectorVisible") }
  }
  public var filesVisible: Bool {
    didSet { defaults.set(filesVisible, forKey: "layout.filesVisible") }
  }
  public var sidebarWidth: Double {
    didSet { defaults.set(sidebarWidth, forKey: "layout.sidebarWidth") }
  }
  public var inspectorWidth: Double {
    didSet { defaults.set(inspectorWidth, forKey: "layout.inspectorWidth") }
  }
  public var filesHeight: Double {
    didSet { defaults.set(filesHeight, forKey: "layout.filesHeight") }
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    remoteBookmarks = RemoteBookmarkStore(defaults: defaults)
    language =
      AppLanguage(rawValue: defaults.string(forKey: "app.language") ?? "") ?? .simplifiedChinese
    appearance = AppAppearance(rawValue: defaults.string(forKey: "app.appearance") ?? "") ?? .system
    terminalTheme =
      TerminalTheme(rawValue: defaults.string(forKey: "terminal.theme") ?? "") ?? .followApp
    storedTerminalFontSize = Self.dimension(
      defaults.double(forKey: "terminal.fontSize"), fallback: 13, range: 10...24)
    sidebarVisible = defaults.object(forKey: "layout.sidebarVisible") as? Bool ?? true
    inspectorVisible = defaults.object(forKey: "layout.inspectorVisible") as? Bool ?? true
    filesVisible = defaults.object(forKey: "layout.filesVisible") as? Bool ?? true
    sidebarWidth = Self.dimension(
      defaults.double(forKey: "layout.sidebarWidth"), fallback: 228, range: 200...340)
    inspectorWidth = Self.dimension(
      defaults.double(forKey: "layout.inspectorWidth"), fallback: 264, range: 240...360)
    filesHeight = Self.dimension(
      defaults.double(forKey: "layout.filesHeight"), fallback: 230, range: 160...420)
  }

  private static func dimension(_ value: Double, fallback: Double, range: ClosedRange<Double>)
    -> Double
  {
    value.isFinite && range.contains(value) ? value : fallback
  }

  public static func forCurrentProcess() -> AppPreferences {
    // A separate domain keeps UI automation from touching the user's choices.
    if ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] == "1",
      let defaults = UserDefaults(suiteName: "ConnDock.UITesting")
    {
      if ProcessInfo.processInfo.environment["CONNDOCK_RESET_PREFERENCES"] == "1" {
        defaults.removePersistentDomain(forName: "ConnDock.UITesting")
      }
      return AppPreferences(defaults: defaults)
    }
    return AppPreferences()
  }

  public func text(_ key: String) -> String { L10n.text(key, language: language) }

  public func resetLayout() {
    sidebarVisible = true
    inspectorVisible = true
    filesVisible = true
    sidebarWidth = 228
    inspectorWidth = 264
    filesHeight = 230
  }
}
