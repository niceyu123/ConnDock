import SSHCoreBridge
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case general, appearance, terminal, iCloud, security, mcp, about
  var id: String { rawValue }
  var titleKey: String { "settings.\(rawValue)" }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "circle.lefthalf.filled"
    case .terminal: "terminal"
    case .iCloud: "icloud"
    case .security: "lock.shield"
    case .mcp: "point.3.connected.trianglepath.dotted"
    case .about: "info.circle"
    }
  }
  static var available: [Self] {
    #if os(macOS)
      allCases
    #else
      allCases.filter { $0 != .mcp }
    #endif
  }
}

public struct SettingsScreen: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(\.colorScheme) private var scheme
  @State private var selection: SettingsCategory = .general
  @State private var path: [SettingsCategory] = []
  @State private var coreVersion: String?
  private let onClose: (() -> Void)?

  public init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

  public var body: some View {
    Group {
      #if os(macOS)
        splitSettings
          .frame(minWidth: 800, idealWidth: 860, minHeight: 600, idealHeight: 680)
      #else
        GeometryReader { geometry in
          if geometry.size.width >= 700 {
            NavigationStack {
              splitSettings
                .navigationTitle(preferences.text("settings.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeToolbar }
            }
          } else {
            compactSettings
          }
        }
      #endif
    }
    .background(WorkspacePalette(scheme: scheme).canvas)
    .environment(\.locale, preferences.language.locale)
    .preferredColorScheme(preferences.appearance.colorScheme)
    .tint(.primary)
  }

  private var splitSettings: some View {
    let palette = WorkspacePalette(scheme: scheme)
    return HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 20) {
        Copy("settings.title").font(.title3.weight(.semibold))
          .padding(.horizontal, 14).padding(.top, 10)
        VStack(spacing: 4) {
          ForEach(SettingsCategory.available) { category in
            Button {
              selection = category
            } label: {
              HStack(spacing: 10) {
                Image(systemName: category.symbol).frame(width: 20).accessibilityHidden(true)
                Copy(category.titleKey)
                Spacer(minLength: 0)
              }
              .font(.body)
              .padding(.horizontal, 12).padding(.vertical, 11)
              .contentShape(Rectangle())
              .background(
                selection == category ? palette.selection : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == category ? .isSelected : [])
            .accessibilityIdentifier("settingsCategory.\(category.rawValue)")
          }
        }
        Spacer()
        Text(verbatim: "ConnDock").font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 14)
      }
      .padding(12)
      .frame(width: 190)
      .background(palette.sidebar)
      Divider()
      detail(selection, showHeading: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  #if os(iOS)
    private var compactSettings: some View {
      NavigationStack(path: $path) {
        List(SettingsCategory.available) { category in
          NavigationLink(value: category) {
            SymbolLabel(key: category.titleKey, symbol: category.symbol)
              .padding(.vertical, 7)
          }
          .accessibilityIdentifier("settingsCategory.\(category.rawValue)")
          .listRowBackground(WorkspacePalette(scheme: scheme).raised)
        }
        .scrollContentBackground(.hidden)
        .background(WorkspacePalette(scheme: scheme).canvas)
        .navigationTitle(preferences.text("settings.title"))
        .toolbar { closeToolbar }
        .navigationDestination(for: SettingsCategory.self) { category in
          detail(category, showHeading: false)
            .navigationTitle(preferences.text(category.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
        }
      }
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
      if let onClose {
        ToolbarItem(placement: .confirmationAction) {
          Button(preferences.text("action.done"), action: onClose)
            .accessibilityIdentifier("closeSettings")
        }
      }
    }
  #endif

  private func detail(_ category: SettingsCategory, showHeading: Bool) -> some View {
    let palette = WorkspacePalette(scheme: scheme)
    return VStack(alignment: .leading, spacing: 0) {
      if showHeading {
        Copy(category.titleKey).font(.title2.weight(.semibold))
          .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 8)
      }
      Form {
        settingsRows(category)
          .listRowBackground(palette.raised)
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
    .background(palette.canvas)
    .task(id: category) {
      guard category == .about else { return }
      coreVersion = await BridgeProbe.shared.readInfo().version
    }
  }

  @ViewBuilder
  private func settingsRows(_ category: SettingsCategory) -> some View {
    @Bindable var preferences = preferences
    switch category {
    case .general:
      Section {
        Picker(preferences.text("settings.language"), selection: $preferences.language) {
          ForEach(AppLanguage.allCases) { language in Copy(language.titleKey).tag(language) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("languagePicker")
      } footer: {
        Copy("settings.languageDetail")
      }
    case .appearance:
      Section {
        Picker(preferences.text("settings.mode"), selection: $preferences.appearance) {
          ForEach(AppAppearance.allCases) { mode in Copy(mode.titleKey).tag(mode) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("appearancePicker")
      } footer: {
        Copy("settings.appearanceDetail")
      }
    case .terminal:
      Section {
        LabeledContent(preferences.text("settings.terminalFont")) {
          Copy("settings.systemMonospaced")
        }
        Stepper(value: $preferences.terminalFontSize, in: 10...24, step: 1) {
          HStack {
            Copy("settings.terminalFontSize")
            Spacer()
            Text(preferences.terminalFontSize, format: .number.precision(.fractionLength(0)))
              .monospacedDigit()
          }
        }.accessibilityIdentifier("terminalFontSize")
        Picker(preferences.text("settings.terminalColors"), selection: $preferences.terminalTheme) {
          ForEach(TerminalTheme.allCases) { theme in Copy(theme.titleKey).tag(theme) }
        }
        .accessibilityIdentifier("terminalThemePicker")
      } footer: {
        Copy("settings.terminalDetail")
      }
    case .iCloud:
      CloudSyncSettings()
    case .security:
      Section {
        LabeledContent {
          Copy("settings.keychainLocal").foregroundStyle(.secondary)
        } label: {
          Copy("settings.credentials")
        }
        LabeledContent {
          Copy("settings.off").foregroundStyle(.secondary)
        } label: {
          Copy("settings.recording")
        }
        LabeledContent {
          Copy("settings.off").foregroundStyle(.secondary)
        } label: {
          Copy("privacy.telemetry")
        }
      } footer: {
        Copy("privacy.trustDetail")
      }
      Section {
        Copy("privacy.localDetail").fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("privacyLocalData")
        Copy("privacy.cloudDetail").fixedSize(horizontal: false, vertical: true)
        Copy("privacy.filesDetail").fixedSize(horizontal: false, vertical: true)
      } header: {
        Copy("privacy.title")
      }
      Section {
        Copy("privacy.directDetail").fixedSize(horizontal: false, vertical: true)
        #if os(macOS)
          Copy("privacy.mcpDetail").fixedSize(horizontal: false, vertical: true)
        #else
          Copy("privacy.backgroundDetail").fixedSize(horizontal: false, vertical: true)
        #endif
      } header: {
        Copy("privacy.connections")
      }
    case .mcp:
      #if os(macOS)
        MCPSettings()
      #else
        EmptyView()
      #endif
    case .about:
      Section {
        LabeledContent {
          Text(verbatim: "ConnDock").foregroundStyle(.secondary)
        } label: {
          Copy("settings.appName")
        }
        LabeledContent {
          Text(
            verbatim:
              "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"
          )
          .monospacedDigit().foregroundStyle(.secondary)
          .accessibilityIdentifier("appBuildVersion")
        } label: {
          Copy("settings.release")
        }
        LabeledContent {
          Copy(buildTypeKey).foregroundStyle(.secondary)
        } label: {
          Copy("settings.buildType")
        }
        LabeledContent {
          if let coreVersion {
            Text(verbatim: coreVersion).monospaced().foregroundStyle(.secondary)
          } else {
            ProgressView().controlSize(.small)
          }
        } label: {
          Copy("settings.rustBridge")
        }
        .accessibilityIdentifier("rustBridgeVersion")
      } footer: {
        Copy("settings.bridgeDetail")
      }
    }
  }
  private var buildTypeKey: String {
    switch Bundle.main.object(forInfoDictionaryKey: "ConnDockBuildConfiguration") as? String {
    case "Local": "settings.localBuild"
    case "Release": "settings.releaseCandidate"
    default: "settings.developmentPreview"
    }
  }

}
