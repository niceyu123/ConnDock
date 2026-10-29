import SwiftUI

struct TerminalWorkspace: View {
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.horizontalSizeClass) private var sizeClass
  var showTabs = true
  var compact = false
  @State private var splitRatio = 0.5
  @State private var dragStart: Double?

  private struct FocusContext: Equatable {
    let selection: UUID
    let split: TerminalSplit?
    let supportsSplit: Bool
  }

  private var supportsSplit: Bool {
    #if os(macOS)
      true
    #else
      sizeClass == .regular
    #endif
  }

  var body: some View {
    VStack(spacing: 0) {
      if showTabs { TerminalTabBar() }
      if supportsSplit, let split = workspace.selectedSplit {
        #if os(macOS)
          if split.axis == .horizontal {
            HSplitView { panes }
          } else {
            VSplitView { panes }
          }
        #else
          GeometryReader { geometry in
            let horizontal = split.axis == .horizontal
            let length = horizontal ? geometry.size.width : geometry.size.height
            let layout =
              horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
              if let first = workspace.visibleTerminalTabs.first {
                TerminalPane(tab: first, compact: compact, showsPaneHeader: true)
                  .frame(
                    width: horizontal ? max(0, length - 12) * splitRatio : nil,
                    height: horizontal ? nil : max(0, length - 12) * splitRatio)
              }
              mobileDivider(horizontal: horizontal, length: length)
              if let last = workspace.visibleTerminalTabs.last {
                TerminalPane(tab: last, compact: compact, showsPaneHeader: true)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
          }
        #endif
      } else if let tab = workspace.selectedTab {
        TerminalPane(tab: tab, compact: compact)
      }
    }
    .task(
      id: FocusContext(
        selection: workspace.selection, split: workspace.selectedSplit, supportsSplit: supportsSplit
      )
    ) {
      let selected = workspace.selection
      await Task.yield()
      guard !Task.isCancelled, workspace.selection == selected,
        !workspace.showNewHost, !workspace.showGroupEditor, workspace.trustPrompt == nil
      else { return }
      workspace.activateTerminal(selected)
    }
  }

  @ViewBuilder private var panes: some View {
    ForEach(workspace.visibleTerminalTabs) { tab in
      TerminalPane(tab: tab, compact: compact, showsPaneHeader: true)
        .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        .id(tab.id)
    }
  }

  #if os(iOS)
    private func mobileDivider(horizontal: Bool, length: CGFloat) -> some View {
      Rectangle().fill(Color.secondary.opacity(0.2))
        .frame(width: horizontal ? 12 : nil, height: horizontal ? nil : 12)
        .overlay {
          Capsule().fill(.secondary)
            .frame(width: horizontal ? 3 : 32, height: horizontal ? 32 : 3)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture().onChanged { value in
            if dragStart == nil { dragStart = splitRatio }
            let distance = horizontal ? value.translation.width : value.translation.height
            splitRatio = min(0.8, max(0.2, (dragStart ?? 0.5) + distance / max(1, length - 12)))
          }.onEnded { _ in dragStart = nil }
        )
        .accessibilityLabel(Text("terminal.split.resize", bundle: .module))
        .accessibilityAdjustableAction { direction in
          splitRatio = min(0.8, max(0.2, splitRatio + (direction == .increment ? 0.1 : -0.1)))
        }
    }
  #endif
}

struct TerminalSplitMenu: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace

  var body: some View {
    ForEach(TerminalSplitAxis.allCases, id: \.rawValue) { axis in
      Button {
        workspace.splitSelected(axis: axis)
      } label: {
        SymbolLabel(key: axis.key, symbol: axis.symbol)
      }
    }
    if workspace.tabs.count > 1 {
      Menu(preferences.text("terminal.split.existing")) {
        ForEach(workspace.tabs.filter { $0.id != workspace.selection }) { tab in
          Button {
            workspace.splitSelected(
              with: tab.id, axis: workspace.selectedSplit?.axis ?? .horizontal)
          } label: {
            if tab.isLocal {
              Copy("terminal.localShell")
            } else if let title = tab.title {
              Text(verbatim: title)
            } else if tab.isWelcome {
              Copy("terminal.disconnected")
            } else {
              Text(verbatim: "\(preferences.text("terminal.tab")) \(tab.ordinal)")
            }
          }
        }
      }
    }
    Button(preferences.text("terminal.split.join")) { workspace.joinSelectedSplit() }
      .disabled(workspace.selectedSplit == nil)
  }
}

private struct TerminalPane: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  let tab: WorkspaceTab
  var compact = false
  var showsPaneHeader = false

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    let terminalScheme = preferences.terminalTheme.resolvedScheme(appScheme: scheme)
    let terminalPalette = WorkspacePalette(scheme: terminalScheme)
    let session = workspace.session(for: tab.id)
    let isLocalTab = tab.isLocal

    VStack(spacing: 0) {
      if showsPaneHeader { paneHeader }

      if let session, session.isActive {
        HStack(spacing: 8) {
          Circle()
            .fill(session.isConnected ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
          Copy(session.statusKey)
            .accessibilityIdentifier("connectionStatus")
          Text(verbatim: "\(session.target.username)@\(session.target.host)")
            .lineLimit(1).truncationMode(.middle)
          Spacer()
          IconButton(key: "action.disconnect", symbol: "stop.fill") {
            workspace.selection = tab.id
            workspace.disconnectSelected()
          }
          .accessibilityIdentifier("terminalDisconnect")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(palette.panel)
        Divider()
      }

      if let key = session?.localErrorKey ?? session?.failure?.localizationKey {
        HStack {
          Image(systemName: "exclamationmark.triangle")
          Copy(key).fixedSize(horizontal: false, vertical: true)
          Spacer()
        }
        .font(.callout).foregroundStyle(.red).padding(10).background(palette.panel)
        .accessibilityIdentifier("terminalError")
        Divider()
      }

      GeometryReader { geometry in
        ZStack {
          if isLocalTab {
            #if os(macOS)
              if let shell = workspace.localShell(for: tab.id) {
                LocalShellCanvas(
                  session: shell, scheme: terminalScheme,
                  fontSize: CGFloat(preferences.terminalFontSize))
              }
            #endif
          } else if session?.connectionOptions.filesOnly == true {
            VStack(spacing: 14) {
              EmptyPanel(
                symbol: "folder.badge.gearshape", title: "host.filesOnly",
                detail: "host.filesOnlyDetail", compact: true)
              Button(preferences.text("sftp.files")) {
                workspace.selection = tab.id
                #if os(macOS)
                  preferences.filesVisible = true
                #else
                  workspace.presentedTool = .files
                #endif
              }
              .buttonStyle(.bordered).disabled(session?.isConnected != true)
            }
          } else if session != nil {
            NativeTerminalView(
              scheme: terminalScheme, accessibilityText: preferences.text("terminal.nativeCanvas"),
              session: session, fontSize: CGFloat(preferences.terminalFontSize)
            )
            .id(session?.id.uuidString ?? "empty.\(tab.id.uuidString)")
            .accessibilityIdentifier("sshTerminal")
          } else {
            ScrollView {
              VStack(spacing: 16) {
                ZStack {
                  RoundedRectangle(cornerRadius: 18)
                    .fill(palette.raised)
                    .frame(width: 68, height: 68)
                  Text(verbatim: ">_")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                  Copy("terminal.ready")
                    .font(compact ? .title3.weight(.bold) : .title2.weight(.bold))
                    .foregroundStyle(.primary)
                  Copy("terminal.emptyDetail")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                }
                HStack(spacing: 12) {
                  Button {
                    workspace.selection = tab.id
                    workspace.showNewHost = true
                  } label: {
                    HStack(spacing: 5) {
                      Image(systemName: "plus").font(.caption.weight(.semibold))
                      Copy("action.newHost")
                      Text(verbatim: "(⌘N)").font(.caption2).opacity(0.8)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                  }
                  .buttonStyle(.borderedProminent)
                  .tint(palette.accent)
                  .foregroundStyle(palette.onAccent)
                  .accessibilityIdentifier("terminalNewHost")

                  #if os(macOS)
                    Button {
                      workspace.openLocalTerminal()
                    } label: {
                      HStack(spacing: 5) {
                        Text(verbatim: ">_").font(.system(size: 11, design: .monospaced))
                        Text(preferences.text("terminal.openLocalTerminal"))
                        Text(verbatim: "(⌘T)").font(.caption2).opacity(0.8)
                      }
                      .padding(.horizontal, 14).padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("terminalOpenLocal")
                  #endif
                }
                Copy("ssh.readyNotice")
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .padding(.top, 4)
              }
              .padding(24)
              .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
          }

          if session?.isActive == true && session?.isConnected == false {
            VStack(spacing: 12) {
              ProgressView()
              Copy(session?.statusKey ?? "ssh.state.connecting")
              Button(preferences.text("action.cancel")) {
                workspace.selection = tab.id
                workspace.disconnectSelected()
              }
            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
          }
        }
      }
      .background(terminalPalette.terminal)
      .accessibilityIdentifier(
        terminalScheme == .dark ? "terminalCanvas.dark" : "terminalCanvas.light")
    }
    .background(palette.terminal)
  }

  private var paneHeader: some View {
    HStack(spacing: 8) {
      Button {
        workspace.activateTerminal(tab.id)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: workspace.selection == tab.id ? "circle.inset.filled" : "circle")
          if tab.isLocal {
            Copy("terminal.localShell")
          } else if let title = tab.title {
            Text(verbatim: title)
          } else if tab.isWelcome {
            Copy("terminal.disconnected")
          } else {
            Copy("terminal.tab")
            Text(tab.ordinal, format: .number)
          }
        }
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("terminalPaneFocus.\(tab.id.uuidString)")
      .accessibilityAddTraits(workspace.selection == tab.id ? .isSelected : [])
      IconButton(key: "terminal.split.join", symbol: "rectangle") {
        workspace.selection = tab.id
        workspace.joinSelectedSplit()
      }.buttonStyle(.plain).accessibilityIdentifier("terminalUnsplit")
      IconButton(key: "action.closeTab", symbol: "xmark") { workspace.closeTab(tab.id) }
        .buttonStyle(.plain)
    }
    .font(.caption).padding(.horizontal, 10).padding(.vertical, 8)
    .foregroundStyle(workspace.selection == tab.id ? Color.accentColor : Color.secondary)
    .background(WorkspacePalette(scheme: scheme).panel)
    .overlay(alignment: .bottom) { Divider() }
  }
}

struct TerminalTabBar: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  @Environment(\.horizontalSizeClass) private var sizeClass
  var toolbarCompact = false

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    HStack(spacing: 0) {
      ScrollViewReader { scroll in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(workspace.tabs) { tab in
              let isSelected = workspace.selection == tab.id
              let session = workspace.session(for: tab.id)
              HStack(spacing: 6) {
                Button {
                  workspace.activateTerminal(tab.id)
                } label: {
                  HStack(spacing: 6) {
                    if tab.isLocal {
                      Text(verbatim: ">_")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                    } else if let session, session.isConnected {
                      Circle().fill(Color.green).frame(width: 6, height: 6)
                    } else if !tab.isWelcome {
                      Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    } else {
                      Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                    }

                    if tab.isLocal {
                      Text(preferences.text("terminal.localShell"))
                        .lineLimit(1)
                    } else if let title = tab.title {
                      Text(verbatim: title)
                        .lineLimit(1)
                        .frame(maxWidth: toolbarCompact ? 160 : nil)
                    } else if tab.isWelcome {
                      Text(preferences.text("terminal.disconnected"))
                    } else {
                      Copy("terminal.tab")
                      Text(tab.ordinal, format: .number).font(.caption2.monospacedDigit())
                    }
                  }
                  .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                if !tab.isWelcome || workspace.tabs.count > 1 {
                  IconButton(key: "action.closeTab", symbol: "xmark") {
                    workspace.closeTab(tab.id)
                  }
                  .font(.system(size: 9))
                  .buttonStyle(.plain)
                  .foregroundStyle(.secondary)
                }
              }
              .padding(.horizontal, 10).padding(.vertical, 5)
              .background {
                if isSelected {
                  RoundedRectangle(cornerRadius: 6)
                    .fill(palette.panel)
                    .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
                } else {
                  RoundedRectangle(cornerRadius: 6)
                    .fill(Color.clear)
                }
              }
              .overlay {
                if isSelected {
                  RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(palette.border.opacity(0.8), lineWidth: 0.8)
                }
              }
              .foregroundStyle(isSelected ? palette.accent : .secondary)
              .contextMenu {
                #if os(macOS)
                  tabSplitActions(tab)
                #else
                  if sizeClass == .regular { tabSplitActions(tab) }
                #endif
              }
              .id(tab.id)
            }

            newTabButton.padding(.leading, 4).id("newTerminalTab")
          }
          .padding(.horizontal, 4)
          .padding(.vertical, 4)
        }
        .onChange(of: workspace.selection) { _, selection in
          scroll.scrollTo(selection, anchor: .trailing)
        }
        .onChange(of: workspace.tabs.count) { oldCount, count in
          if count > oldCount {
            scroll.scrollTo("newTerminalTab", anchor: .trailing)
          }
        }
      }
    }
    .frame(height: 38)
  }

  private var newTabButton: some View {
    IconButton(key: "action.newTerminal", symbol: "plus") { workspace.addTerminal() }
      .buttonStyle(.plain)
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("newTerminalTab")
  }

  @ViewBuilder private func tabSplitActions(_ tab: WorkspaceTab) -> some View {
    ForEach(TerminalSplitAxis.allCases, id: \.rawValue) { axis in
      Button {
        workspace.selection = tab.id
        workspace.splitSelected(axis: axis)
      } label: {
        SymbolLabel(key: axis.key, symbol: axis.symbol)
      }
    }
    Button(preferences.text("terminal.split.join")) {
      workspace.selection = tab.id
      workspace.joinSelectedSplit()
    }
  }
}
