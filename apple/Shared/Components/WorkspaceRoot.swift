import SSHCoreBridge
import SwiftUI

public struct WorkspaceRoot: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @State private var hostEditorDismissed = true
  @State private var groupEditorDismissed = true
  public init() {}

  public var body: some View {
    @Bindable var workspace = workspace
    Group {
      #if os(macOS)
        DesktopWorkspace()
      #else
        MobileWorkspace()
      #endif
    }
    .sheet(
      isPresented: $workspace.showNewHost,
      onDismiss: {
        workspace.finishHostEditing()
        hostEditorDismissed = true
      }
    ) {
      NewHostSheet(
        host: workspace.editingHostID.flatMap { workspace.library?.host($0) },
        target: workspace.reconnectTarget, requireCredential: workspace.requireCredentialInput,
        testOnly: workspace.editorTestOnly, persistenceAvailable: workspace.library != nil,
        connectionOptions: workspace.reconnectOptions)
    }
    .sheet(
      isPresented: $workspace.showGroupEditor,
      onDismiss: {
        workspace.editingGroupID = nil
        groupEditorDismissed = true
      }
    ) {
      HostGroupSheet(group: workspace.library?.groups.first { $0.id == workspace.editingGroupID })
    }
    .sheet(
      item: Binding(
        get: {
          !workspace.showNewHost && !workspace.showGroupEditor && hostEditorDismissed
            && groupEditorDismissed
            ? workspace.trustPrompt : nil
        },
        set: { _ in })
    ) { challenge in HostKeySheet(challenge: challenge) }
    .sheet(
      item: Binding(
        get: {
          !workspace.showNewHost && !workspace.showGroupEditor && hostEditorDismissed
            && groupEditorDismissed
            && workspace.trustPrompt == nil ? workspace.authenticationPrompt : nil
        }, set: { _ in })
    ) { challenge in
      InteractiveAuthenticationSheet(challenge: challenge).id(challenge.id)
    }
    .onChange(of: workspace.showNewHost) { _, value in if value { hostEditorDismissed = false } }
    .onChange(of: workspace.showGroupEditor) { _, value in if value { groupEditorDismissed = false }
    }
    .alert(
      preferences.text("common.error"),
      isPresented: Binding(
        get: { workspace.operationErrorKey != nil },
        set: { if !$0 { workspace.operationErrorKey = nil } }
      )
    ) {
      Button(preferences.text("action.done")) { workspace.operationErrorKey = nil }
    } message: {
      Copy(workspace.operationErrorKey ?? "storage.error.unavailable")
    }
    .task {
      #if os(macOS)
        workspace.configureMCP(preferences: preferences)
      #endif
      await workspace.library?.retryCredentialCleanup()
      workspace.cloudSync?.resume()
    }
    .environment(\.locale, preferences.language.locale)
    .preferredColorScheme(preferences.appearance.colorScheme)
    .tint(.primary)
  }
}

#if os(macOS)
  import AppKit

  private struct WorkspaceActiveKey: FocusedValueKey { typealias Value = Bool }
  extension FocusedValues {
    fileprivate var sshWorkspaceActive: Bool? {
      get { self[WorkspaceActiveKey.self] }
      set { self[WorkspaceActiveKey.self] = newValue }
    }
  }

  struct DesktopWorkspace: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @State private var version: String?

    var body: some View {
      @Bindable var preferences = preferences
      let palette = WorkspacePalette(scheme: scheme)
      let leftHeaderWidth: CGFloat = preferences.sidebarVisible ? preferences.sidebarWidth : 138

      VStack(spacing: 0) {
        // 1. 顶部全局导航 (Header & Tabs) 与上下对齐
        HStack(spacing: 0) {
          // 顶栏左侧固定区 (展开宽度严格与下方左栏一致，折叠自适应 138px，右侧带分割线)
          HStack(spacing: 4) {
            Spacer().frame(width: 70)  // 避让原生交通灯
            BrandIcon(size: 22)
            if preferences.sidebarVisible {
              Text(verbatim: "ConnDock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            Button {
              withAnimation(.easeInOut(duration: 0.2)) {
                preferences.sidebarVisible.toggle()
              }
            } label: {
              Image(systemName: "sidebar.left")
                .font(.system(size: 11))
                .padding(5)
                .background(
                  preferences.sidebarVisible ? palette.raised : Color.clear,
                  in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(preferences.sidebarVisible ? palette.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(preferences.text("layout.sidebar"))
            .accessibilityIdentifier("toggleSidebar")
          }
          .padding(.trailing, 8)
          .frame(width: leftHeaderWidth)
          .animation(.easeInOut(duration: 0.2), value: preferences.sidebarVisible)

          // Match both the lower resize handle's width and its visible line.
          Color.clear
            .frame(width: preferences.sidebarVisible ? ResizableDivider.handleThickness : 1)
            .overlay(alignment: .leading) {
              Rectangle()
                .fill(palette.border)
                .frame(width: 1)
                .offset(x: preferences.sidebarVisible ? ResizableDivider.handleThickness / 2 : 0)
            }

          // 顶部中间多会话标签与右侧工具区
          HStack(spacing: 0) {
            TerminalTabBar(toolbarCompact: true)

            Spacer(minLength: 8)

            // 顶栏右侧工具区
            HStack(spacing: 5) {
              Button {
                workspace.openLocalTerminal()
              } label: {
                HStack(spacing: 4) {
                  Text(verbatim: ">_").font(.system(size: 10, weight: .bold, design: .monospaced))
                  Text(preferences.text("terminal.localTerminal"))
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 5))
              }
              .buttonStyle(.plain)
              .help(preferences.text("terminal.openLocalTerminal"))
              .accessibilityIdentifier("headerLocalTerminal")

              IconButton(
                key: preferences.inspectorVisible
                  ? "layout.hideInspector" : "layout.showInspector",
                symbol: "sidebar.right"
              ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                  preferences.inspectorVisible.toggle()
                }
              }
              .buttonStyle(.plain)
              .font(.system(size: 11))
              .background(
                preferences.inspectorVisible ? palette.raised : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
              )
              .foregroundStyle(preferences.inspectorVisible ? palette.accent : .secondary)
              .accessibilityIdentifier("layout.toggleRightPanel")
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 10)
          }
        }
        .frame(height: 38)
        .background(palette.panel)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
          Rectangle().fill(palette.border).frame(height: 1)
        }

        // 2. 主体三栏独立折叠布局
        HStack(spacing: 0) {
          if preferences.sidebarVisible {
            HostSidebar()
              .frame(width: preferences.sidebarWidth)
              .transition(.move(edge: .leading))
            ResizableDivider(
              dimension: $preferences.sidebarWidth, axis: .horizontal,
              range: 200...340, labelKey: "layout.resizeSidebar")
          }

          VStack(spacing: 0) {
            TerminalWorkspace(showTabs: false)
              .frame(maxWidth: .infinity, maxHeight: .infinity)

            if preferences.filesVisible {
              ResizableDivider(
                dimension: $preferences.filesHeight, axis: .vertical,
                range: 160...420, direction: -1,
                labelKey: "layout.resizeFiles")
            }
            FilesPanel()
              .frame(height: preferences.filesVisible ? preferences.filesHeight : 36)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          if preferences.inspectorVisible {
            ResizableDivider(
              dimension: $preferences.inspectorWidth, axis: .horizontal,
              range: 240...360, direction: -1,
              labelKey: "layout.resizeInspector")
            MonitorPanel()
              .frame(width: 240)
              .transition(.move(edge: .trailing))
          }
        }
        .animation(.easeInOut(duration: 0.2), value: preferences.sidebarVisible)
        .animation(.easeInOut(duration: 0.2), value: preferences.filesVisible)
        .animation(.easeInOut(duration: 0.2), value: preferences.inspectorVisible)

        // 3. 底部全局状态栏 (Footer) 高度固定 24px
        Rectangle().fill(palette.border).frame(height: 1)
        HStack(spacing: 8) {
          HStack(spacing: 5) {
            if let session = workspace.selectedSession, session.isConnected {
              Circle().fill(Color.green).frame(width: 6, height: 6)
              Text(
                verbatim:
                  "\(preferences.text("ssh.state.connected")) \(session.target.title) (\(session.target.host))"
              )
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.primary)
            } else if workspace.selectedTab?.isLocal == true {
              Circle().fill(Color.blue).frame(width: 6, height: 6)
              Text(preferences.text("terminal.localSession"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            } else {
              Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
              Text(preferences.text("terminal.disconnected"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("footerConnectionStatus")

          Spacer()

          HStack(spacing: 6) {
            Text(verbatim: "Rust \(version ?? "0.1.0")")
              .monospacedDigit()
            Text(verbatim: "|")
              .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
              Image(systemName: "shield.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
              Copy(workspace.storageStatusKey)
            }
          }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(palette.panel)
      }
      .background(palette.canvas)
      .frame(minWidth: 1040, minHeight: 680)
      .focusedSceneValue(\.sshWorkspaceActive, true)
      .task { version = await BridgeProbe.shared.readInfo().version }
      .onAppear {
        // 初始状态智能联动：未连接服务器时，隐藏空监控栏，底栏折叠为标题条
        if workspace.selectedSession?.isConnected != true {
          preferences.sidebarVisible = true
          preferences.filesVisible = false
          preferences.inspectorVisible = false
        }
      }
      .onChange(of: workspace.selectedSession?.isConnected) { _, isConnected in
        withAnimation(.easeInOut(duration: 0.2)) {
          if isConnected == true {
            preferences.filesVisible = true
            preferences.inspectorVisible = true
          }
        }
      }
      .onChange(of: workspace.selection) { _, _ in
        if let session = workspace.selectedSession, session.isConnected {
          withAnimation(.easeInOut(duration: 0.2)) {
            preferences.filesVisible = true
            preferences.inspectorVisible = true
          }
        } else if workspace.selectedSession == nil {
          withAnimation(.easeInOut(duration: 0.2)) {
            preferences.inspectorVisible = false
            preferences.filesVisible = false
          }
        }
      }
    }
  }

  struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class DragView: NSView {
      override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
      }
    }
  }

  public struct WorkspaceCommands: Commands {
    @FocusedValue(\.sshWorkspaceActive) private var workspaceActive
    @Bindable private var preferences: AppPreferences
    @Bindable private var workspace: WorkspaceState

    public init(preferences: AppPreferences, workspace: WorkspaceState) {
      self.preferences = preferences
      self.workspace = workspace
    }

    public var body: some Commands {
      CommandGroup(replacing: .newItem) {
        Button(preferences.text("action.newHost")) { workspace.showNewHost = true }
          .keyboardShortcut("n")
        Button(preferences.text("action.findHost")) {
          preferences.sidebarVisible = true
          workspace.searchFocused = true
        }.keyboardShortcut("k")
        Button(preferences.text("action.newTerminal")) { workspace.addTerminal() }.keyboardShortcut(
          "t")
      }
      CommandGroup(replacing: .appSettings) {
        SettingsLink { Text(verbatim: preferences.text("settings.menu")) }.keyboardShortcut(",")
      }
      CommandGroup(after: .newItem) {
        if workspaceActive == true {
          Button(preferences.text("action.closeTab")) { workspace.closeTab(workspace.selection) }
            .keyboardShortcut("w")
        }
      }
      CommandMenu(preferences.text("layout.title")) {
        Button(preferences.text("terminal.split.horizontal")) {
          workspace.splitSelected(axis: .horizontal)
        }.keyboardShortcut("d")
        Button(preferences.text("terminal.split.vertical")) {
          workspace.splitSelected(axis: .vertical)
        }.keyboardShortcut("d", modifiers: [.command, .shift])
        Menu(preferences.text("terminal.split.title")) {
          TerminalSplitMenu().environment(preferences).environment(workspace)
        }
        Divider()
        Toggle(preferences.text("layout.sidebar"), isOn: $preferences.sidebarVisible)
          .keyboardShortcut("b")
        Toggle(preferences.text("layout.inspector"), isOn: $preferences.inspectorVisible)
          .keyboardShortcut("i")
        Toggle(preferences.text("layout.files"), isOn: $preferences.filesVisible).keyboardShortcut(
          "j")
        Divider()
        Button(preferences.text("layout.reset")) { preferences.resetLayout() }
      }
    }
  }
#endif
