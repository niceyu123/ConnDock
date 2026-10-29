#if os(iOS)
  import SwiftUI

  private enum PhoneTab { case hosts, terminal, settings }

  struct MobileWorkspace: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: PhoneTab = .hosts
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var toolDetent: PresentationDetent = .large

    var body: some View {
      @Bindable var workspace = workspace
      Group {
        if sizeClass == .regular { tablet } else { phone }
      }
      .sheet(item: $workspace.presentedTool) { tool in
        NavigationStack {
          Group {
            if tool == .files { FilesPanel() } else { MonitorPanel() }
          }
          .navigationTitle(preferences.text(tool == .files ? "sftp.files" : "monitor.resources"))
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button(preferences.text("action.done")) { workspace.presentedTool = nil }
            }
          }
        }
        .environment(\.locale, preferences.language.locale)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .presentationDetents([.medium, .large], selection: $toolDetent)
      }
      .sheet(isPresented: $showSettings) {
        SettingsScreen(onClose: { showSettings = false })
      }
      .onChange(of: workspace.connectionRevision) { _, _ in tab = .terminal }
    }

    private var phone: some View {
      TabView(selection: $tab) {
        NavigationStack {
          PhoneHostsView(openTerminal: { tab = .terminal })
        }
        .tabItem { SymbolLabel(key: "navigation.hosts", symbol: "server.rack") }.tag(PhoneTab.hosts)
        NavigationStack {
          TerminalWorkspace(compact: true)
            .navigationTitle(preferences.text("navigation.terminal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { terminalTools }
            .safeAreaInset(edge: .bottom, spacing: 0) { keyboardBar }
        }
        .tabItem { SymbolLabel(key: "navigation.terminal", symbol: "terminal") }.tag(
          PhoneTab.terminal)
        SettingsScreen()
          .tabItem { SymbolLabel(key: "settings.title", symbol: "gearshape") }.tag(
            PhoneTab.settings)
      }
    }

    private var tablet: some View {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        HostSidebar()
          .navigationTitle(preferences.text("navigation.hosts"))
          .toolbar {
            ToolbarItem(placement: .bottomBar) {
              Button {
                showSettings = true
              } label: {
                SymbolLabel(key: "settings.title", symbol: "gearshape")
              }
              .accessibilityIdentifier("openSettings")
            }
          }
          .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
      } detail: {
        TerminalWorkspace(compact: true)
          .navigationTitle("ConnDock")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { terminalTools }
          .safeAreaInset(edge: .bottom, spacing: 0) { keyboardBar }
      }
      .navigationSplitViewStyle(.balanced)
    }

    @ToolbarContentBuilder
    private var terminalTools: some ToolbarContent {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if sizeClass == .regular {
          Menu {
            TerminalSplitMenu()
          } label: {
            SymbolLabel(key: "terminal.split.title", symbol: "rectangle.split.2x1")
          }
          .accessibilityIdentifier("terminalSplitMenu")
        }
        Button {
          workspace.presentedTool = .files
        } label: {
          SymbolLabel(key: "sftp.files", symbol: "folder")
        }
        .accessibilityIdentifier("openFiles")
        Button {
          workspace.presentedTool = .monitor
        } label: {
          SymbolLabel(key: "monitor.resources", symbol: "gauge.with.dots.needle.33percent")
        }
        .accessibilityIdentifier("openMonitor")
        if sizeClass == .regular {
          Button {
            showSettings = true
          } label: {
            SymbolLabel(key: "settings.title", symbol: "gearshape")
          }
          .accessibilityIdentifier("tabletSettings")
        }
      }
    }

    private var keyboardBar: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(["key.escape", "key.tab", "key.control", "key.alt"], id: \.self) { key in
            Button {
              guard let session = workspace.selectedSession else { return }
              switch key {
              case "key.escape": session.surface.view.send([27])
              case "key.tab": session.surface.view.send([9])
              case "key.control": session.surface.view.controlModifier.toggle()
              case "key.alt": session.surface.view.metaModifier.toggle()
              default: break
              }
              _ = session.surface.view.becomeFirstResponder()
            } label: {
              Copy(key).font(.system(.callout, design: .monospaced)).frame(
                minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered).disabled(workspace.selectedSession?.canSendInput != true)
          }
          ForEach(["arrow.left", "arrow.down", "arrow.up", "arrow.right"], id: \.self) { symbol in
            Button {
              guard let view = workspace.selectedSession?.surface.view else { return }
              view.send(
                TerminalInput.arrow(symbol, applicationCursor: view.getTerminal().applicationCursor)
              )
            } label: {
              Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(preferences.text("key.\(symbol)"))
            .buttonStyle(.bordered).disabled(workspace.selectedSession?.canSendInput != true)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
      }
      .background(.bar)
    }
  }

  private struct PhoneHostsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @State private var filter: HostFilter = .all
    let openTerminal: () -> Void

    @State private var deletingGroupID: UUID?

    var body: some View {
      @Bindable var workspace = workspace
      let palette = WorkspacePalette(scheme: scheme)
      VStack(spacing: 0) {
        HStack {
          SymbolLabel(key: workspace.storageStatusKey, symbol: "lock.shield")
          Spacer()
          Text(workspace.library?.hosts.count ?? 0, format: .number).monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        Picker(preferences.text("hosts.filter"), selection: $filter) {
          ForEach(HostFilter.allCases) { item in Copy(item.key).tag(item) }
        }
        .pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
        .accessibilityIdentifier("hostFilter")
        HStack {
          Picker(preferences.text("hosts.groups"), selection: $workspace.selectedGroupID) {
            Copy("hosts.allGroups").tag(UUID?.none)
            ForEach(workspace.library?.groups ?? []) { group in
              Text(verbatim: group.name).tag(Optional(group.id))
            }
          }.labelsHidden()
          Spacer()
          Menu {
            Button(preferences.text("group.new")) { workspace.requestGroupEditor() }
            if let id = workspace.selectedGroupID {
              Button(preferences.text("group.rename")) { workspace.requestGroupEditor(id) }
              Button(preferences.text("action.delete"), role: .destructive) { deletingGroupID = id }
            }
          } label: {
            Image(systemName: "folder.badge.gearshape").frame(minWidth: 44, minHeight: 44)
          }
          .accessibilityLabel(preferences.text("hosts.groups"))
          .accessibilityIdentifier("phoneGroups")
        }.padding(.horizontal, 20)
        Divider()
        SavedHostList(filter: filter, groupID: workspace.selectedGroupID).frame(
          maxHeight: .infinity)
        Divider()
        HStack {
          Button {
            workspace.showNewHost = true
          } label: {
            SymbolLabel(key: "action.newHost", symbol: "plus").frame(
              maxWidth: .infinity, minHeight: 36)
          }
          .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.onAccent)
          .accessibilityIdentifier("phoneNewHost")
          Button(action: openTerminal) {
            Image(systemName: "terminal").frame(minWidth: 44, minHeight: 44)
          }
          .accessibilityLabel(preferences.text("hosts.openWorkspace"))
          .accessibilityIdentifier("openTerminalWorkspace")
        }.padding(.horizontal, 20).padding(.vertical, 10)
      }
      .background(palette.canvas)
      .navigationTitle(preferences.text("navigation.hosts"))
      .searchable(text: $workspace.search, prompt: Text(verbatim: preferences.text("hosts.search")))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          BrandIcon(size: 28)
        }
        ToolbarItem(placement: .topBarTrailing) {
          SSHConfigImportButton(iconOnly: true)
          Button {
            workspace.showNewHost = true
          } label: {
            SymbolLabel(key: "action.newHost", symbol: "plus")
          }
        }
      }
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
            workspace.selectedGroupID = nil
          } catch {
            workspace.operationErrorKey =
              (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
          }
          deletingGroupID = nil
        }
      } message: {
        Copy("group.deleteDetail")
      }
    }

  }
#endif
