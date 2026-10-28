import SwiftUI

struct TerminalWorkspace: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  var showTabs = true
  var compact = false

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    let terminalScheme = preferences.terminalTheme.resolvedScheme(appScheme: scheme)
    let terminalPalette = WorkspacePalette(scheme: terminalScheme)
    let session = workspace.selectedSession
    let isLocalTab = workspace.selectedTab?.isLocal == true

    VStack(spacing: 0) {
      if showTabs { TerminalTabBar() }

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
              if let shell = workspace.selectedLocalShell {
                LocalShellCanvas(
                  session: shell, scheme: terminalScheme,
                  fontSize: CGFloat(preferences.terminalFontSize))
              }
            #endif
          } else if session != nil {
            NativeTerminalView(
              scheme: terminalScheme, accessibilityText: preferences.text("terminal.nativeCanvas"),
              session: session, fontSize: CGFloat(preferences.terminalFontSize)
            )
            .id(session?.id.uuidString ?? "empty.\(workspace.selection.uuidString)")
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
              Button(preferences.text("action.cancel")) { workspace.disconnectSelected() }
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
}

struct TerminalTabBar: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
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
                  workspace.selection = tab.id
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
}
