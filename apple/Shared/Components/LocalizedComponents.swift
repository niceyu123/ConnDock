import SwiftUI

struct Copy: View {
  @Environment(AppPreferences.self) private var preferences
  let key: String
  init(_ key: String) { self.key = key }
  var body: some View { Text(verbatim: preferences.text(key)) }
}

struct SymbolLabel: View {
  let key: String
  let symbol: String
  var body: some View {
    Label {
      Copy(key)
    } icon: {
      Image(systemName: symbol)
    }
  }
}

struct EmptyPanel: View {
  let symbol: String
  let title: String
  let detail: String
  var compact = false

  var body: some View {
    VStack(spacing: compact ? 10 : 16) {
      Image(systemName: symbol)
        .font(.system(size: compact ? 24 : 40, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Copy(title).font(compact ? .headline : .title2.weight(.semibold))
      Copy(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 350)
    }
    .padding(compact ? 20 : 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct IconButton: View {
  @Environment(AppPreferences.self) private var preferences
  let key: String
  let symbol: String
  let action: () -> Void
  private var targetSize: CGFloat {
    #if os(macOS)
      24
    #else
      44
    #endif
  }
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).frame(minWidth: targetSize, minHeight: targetSize)
    }
    .accessibilityLabel(preferences.text(key))
    .help(preferences.text(key))
  }
}
