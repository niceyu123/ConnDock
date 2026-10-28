import SwiftUI

struct SavedHostList: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  let filter: HostFilter
  var groupID: UUID?
  @State private var deletingID: UUID?

  private var hosts: [StoredHost] {
    let rows =
      workspace.library?.matching(
        search: workspace.search,
        favoritesOnly: filter == .favorites, recentOnly: filter == .recent) ?? []
    return groupID.map { id in rows.filter { $0.groupID == id } } ?? rows
  }

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    Group {
      if workspace.library == nil {
        VStack(spacing: 16) {
          EmptyPanel(
            symbol: "externaldrive.badge.exclamationmark", title: "storage.error.unavailable",
            detail: "storage.loadHint")
          Button(preferences.text("action.retry")) { workspace.loadLibrary() }
        }.padding()
      } else if hosts.isEmpty {
        EmptyPanel(
          symbol: workspace.search.isEmpty ? "server.rack" : "magnifyingglass",
          title: workspace.search.isEmpty ? "hosts.emptyList" : "hosts.noResults",
          detail: "hosts.emptyDetail"
        )
        .padding()
      } else {
        List {
          ForEach(hosts) { host in
            row(host)
              .listRowBackground(workspace.selectedHostID == host.id ? palette.selection : .clear)
              .contextMenu { actions(host) }
              #if os(iOS)
                .swipeActions {
                  Button(role: .destructive) {
                    deletingID = host.id
                  } label: {
                    SymbolLabel(key: "action.delete", symbol: "trash")
                  }
                  Button {
                    toggleFavorite(host)
                  } label: {
                    SymbolLabel(
                      key: host.favorite ? "hosts.unfavorite" : "hosts.favorite", symbol: "star")
                  }.tint(.orange)
                }
              #endif
          }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .accessibilityIdentifier("savedHostList")
      }
    }
    .overlay(alignment: .top) {
      if let refreshError = workspace.library?.refreshErrorKey {
        Button {
          do { try workspace.library?.refresh() } catch {
            workspace.operationErrorKey = refreshError
          }
        } label: {
          Copy(refreshError).font(.caption).padding(10)
        }.buttonStyle(.bordered).padding()
      }
    }
    .overlay(alignment: .bottom) {
      if workspace.library?.cleanupPending == true {
        Button {
          Task { await workspace.library?.retryCredentialCleanup() }
        } label: {
          Copy("host.cleanupPending").font(.caption).padding(10)
        }
        .buttonStyle(.bordered).padding()
      }
    }
    .confirmationDialog(
      preferences.text("hosts.deleteTitle"),
      isPresented: Binding(
        get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }), titleVisibility: .visible
    ) {
      Button(preferences.text("action.delete"), role: .destructive) {
        guard let id = deletingID else { return }
        deletingID = nil
        Task {
          do {
            try await workspace.library?.deleteHost(id)
            if workspace.selectedHostID == id { workspace.selectedHostID = nil }
          } catch {
            workspace.operationErrorKey =
              (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
          }
        }
      }
    } message: {
      Copy("hosts.deleteDetail")
    }
  }

  private func row(_ host: StoredHost) -> some View {
    Button {
      workspace.selectedHostID = host.id
      #if os(iOS)
        Task { await workspace.connectSavedHost(host.id) }
      #endif
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "server.rack").frame(width: 20).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: host.title).font(.body.weight(.medium)).lineLimit(1)
          Text(verbatim: "\(host.username)@\(host.hostname):\(host.port)")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 4)
        if workspace.openingHostID == host.id {
          ProgressView().controlSize(.small)
        } else if workspace.isConnected(host) {
          Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
            .accessibilityLabel(preferences.text("ssh.state.connected"))
        }
        if host.favorite {
          Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel(
            preferences.text("hosts.favorite"))
        }
      }
      .foregroundStyle(.primary).padding(.vertical, 6).frame(minHeight: 34).contentShape(
        Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(workspace.openingHostID != nil || workspace.library?.isBusy == true)
    .accessibilityIdentifier("savedHost.\(host.id.uuidString)")
    #if os(macOS)
      .simultaneousGesture(
        TapGesture(count: 2).onEnded { Task { await workspace.connectSavedHost(host.id) } })
    #endif
  }

  @ViewBuilder private func actions(_ host: StoredHost) -> some View {
    Button(preferences.text("action.connect")) {
      Task { await workspace.connectSavedHost(host.id) }
    }
    Button(preferences.text("hosts.openNewTab")) {
      Task { await workspace.connectSavedHost(host.id, newTab: true) }
    }
    Button(preferences.text("hosts.testConnection")) {
      Task { await workspace.connectSavedHost(host.id, testOnly: true) }
    }
    Divider()
    Button(preferences.text("host.edit")) { workspace.requestEditHost(host.id) }
    Button(preferences.text(host.favorite ? "hosts.unfavorite" : "hosts.favorite")) {
      toggleFavorite(host)
    }
    Divider()
    Button(preferences.text("action.delete"), role: .destructive) { deletingID = host.id }
  }

  private func toggleFavorite(_ host: StoredHost) {
    do { try workspace.library?.toggleFavorite(host.id) } catch {
      workspace.operationErrorKey =
        (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
    }
  }
}
