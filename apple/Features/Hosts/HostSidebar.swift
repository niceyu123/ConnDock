import SwiftUI

enum HostFilter: String, CaseIterable, Identifiable {
  case all, favorites, recent
  var id: String { rawValue }
  var key: String {
    switch self {
    case .all: "hosts.filterAll"
    case .favorites: "hosts.filterFavorites"
    case .recent: "hosts.filterRecent"
    }
  }
  var symbol: String {
    switch self {
    case .all: "server.rack"
    case .favorites: "star"
    case .recent: "clock"
    }
  }
}

struct HostSidebar: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  @State private var filter: HostFilter = .all
  @State private var groupsExpanded = true
  @State private var deletingGroupID: UUID?
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var workspace = workspace
    let palette = WorkspacePalette(scheme: scheme)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        BrandIcon()
        Copy("hosts.localWorkspace").font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
        #if os(macOS)
          IconButton(key: "layout.hideSidebar", symbol: "chevron.left") {
            withAnimation(.easeInOut(duration: 0.2)) {
              preferences.sidebarVisible = false
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("layout.hideSidebar")
        #endif
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField(preferences.text("hosts.search"), text: $workspace.search)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .accessibilityIdentifier("hostSearch")
        #if os(macOS)
          Text(verbatim: "⌘K").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
        #endif
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
      .padding(.horizontal, 10)
      .padding(.bottom, 8)

      HStack(spacing: 2) {
        ForEach(HostFilter.allCases) { item in
          Button {
            withAnimation(.easeInOut(duration: 0.15)) {
              filter = item
              workspace.selectedGroupID = nil
            }
          } label: {
            HStack(spacing: 3) {
              if item == .favorites {
                Image(systemName: "star.fill").font(.system(size: 8)).accessibilityHidden(true)
              } else if item == .recent {
                Image(systemName: "clock").font(.system(size: 8)).accessibilityHidden(true)
              }
              Copy(item.key)
                .font(.system(size: 11, weight: filter == item ? .medium : .regular))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
              filter == item ? palette.panel : Color.clear,
              in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(filter == item ? palette.accent : .secondary)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(filter == item ? .isSelected : [])
          .accessibilityIdentifier("filter.\(item.rawValue)")
        }
      }
      .padding(2)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
      .padding(.horizontal, 10)
      .padding(.bottom, 8)

      Divider().padding(.horizontal, 10).padding(.bottom, 8)
      VStack(spacing: 6) {
        HStack {
          Button {
            groupsExpanded.toggle()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: groupsExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).accessibilityHidden(true)
              SymbolLabel(key: "hosts.groups", symbol: "folder")
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 20)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("hostGroupsDisclosure")
          .accessibilityValue(
            preferences.text(groupsExpanded ? "groups.expanded" : "groups.collapsed"))
          Spacer()
          IconButton(key: "group.new", symbol: "plus") { workspace.requestGroupEditor() }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newHostGroup")
        }
        if groupsExpanded {
          ScrollView {
            VStack(alignment: .leading, spacing: 3) {
              if workspace.library?.groups.isEmpty != false {
                Copy("hosts.noGroups").font(.caption).foregroundStyle(.secondary).padding(
                  .vertical, 6)
              }
              ForEach(workspace.library?.groups ?? []) { group in
                Button {
                  filter = .all
                  workspace.selectedGroupID = group.id
                } label: {
                  HStack {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(verbatim: group.name).lineLimit(1)
                    Spacer()
                    Text(
                      workspace.library?.hosts.filter { $0.groupID == group.id }.count ?? 0,
                      format: .number
                    )
                    .font(.caption).foregroundStyle(.secondary)
                  }.padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspace.selectedGroupID == group.id ? palette.accent : .primary)
                .contextMenu {
                  Button(preferences.text("group.rename")) {
                    workspace.requestGroupEditor(group.id)
                  }
                  Button(preferences.text("action.delete"), role: .destructive) {
                    deletingGroupID = group.id
                  }
                }
              }
            }
          }.frame(height: min(140, max(40, CGFloat(workspace.library?.groups.count ?? 0) * 28)))
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
      Divider()
      SavedHostList(filter: filter, groupID: workspace.selectedGroupID)
        .frame(maxHeight: .infinity)

      HStack(spacing: 6) {
        Button {
          workspace.showNewHost = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "plus").font(.caption.weight(.semibold))
            Copy("action.newHost")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("sidebarNewHost")

        SSHConfigImportButton(iconOnly: true)
          .buttonStyle(.bordered)

        #if os(macOS)
          SettingsLink {
            Image(systemName: "gearshape")
              .font(.caption)
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.bordered)
          .accessibilityLabel(preferences.text("settings.title"))
          .help(preferences.text("settings.title"))
          .accessibilityIdentifier("openSettings")
        #endif
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .background(palette.sidebar)
    .confirmationDialog(
      preferences.text("group.deleteTitle"),
      isPresented: Binding(
        get: { deletingGroupID != nil }, set: { if !$0 { deletingGroupID = nil } }),
      titleVisibility: .visible
    ) {
      Button(preferences.text("action.delete"), role: .destructive) {
        guard let id = deletingGroupID else { return }
        do {
          try workspace.library?.deleteGroup(id)
          if workspace.selectedGroupID == id { workspace.selectedGroupID = nil }
        } catch {
          workspace.operationErrorKey =
            (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
        }
        deletingGroupID = nil
      }
    } message: {
      Copy("group.deleteDetail")
    }
    .onChange(of: workspace.searchFocused) { _, value in searchFocused = value }
    .onChange(of: searchFocused) { _, value in workspace.searchFocused = value }
  }
  private func count(_ filter: HostFilter) -> Int {
    workspace.library?.matching(favoritesOnly: filter == .favorites, recentOnly: filter == .recent)
      .count ?? 0
  }

}
