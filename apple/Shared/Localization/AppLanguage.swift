import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  public var id: String { rawValue }
  public var locale: Locale { Locale(identifier: rawValue) }
  var titleKey: String {
    switch self {
    case .simplifiedChinese: "language.chinese"
    case .english: "language.english"
    }
  }
}

public enum L10n {
  /// Explicit bundle selection also covers native menu titles and AppKit/UIKit
  /// labels, which don't consume SwiftUI's Locale environment.
  public static func text(_ key: String, language: AppLanguage) -> String {
    guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
    return bundle.localizedString(forKey: key, value: nil, table: nil)
  }
}
