#if os(macOS)
  import AppKit
  import Observation
  import SwiftTerm
  import SwiftUI

  // Keep the native view and PTY alive when the user switches tabs.
  @MainActor @Observable
  final class LocalShellSession: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let view = LocalProcessTerminalView(frame: .zero)
    private(set) var ended = false

    override init() {
      super.init()
      view.processDelegate = self
      view.changeScrollback(5000)
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.textArea)
      view.setAccessibilityIdentifier("localTerminal")
      view.startProcess(executable: "/bin/zsh", args: ["-i"])
      if !view.process.running { ended = true }
    }

    func close() {
      guard view.process.running else { return }
      let pid = view.process.shellPid
      // The PTY's foreground job may be a different process group than zsh.
      let foreground = tcgetpgrp(view.process.childfd)
      if foreground > 0 { _ = kill(-foreground, SIGHUP) }
      view.terminate()
      if pid > 0 {
        DispatchQueue.global(qos: .utility).async {
          var status: Int32 = 0
          _ = waitpid(pid, &status, 0)
        }
      }
      ended = true
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { ended = true }
  }

  struct LocalShellCanvas: View {
    @Environment(AppPreferences.self) private var preferences
    let session: LocalShellSession
    let scheme: ColorScheme
    let fontSize: CGFloat

    var body: some View {
      VStack(spacing: 0) {
        HStack {
          Copy(session.ended ? "terminal.localEnded" : "terminal.localSandboxNotice")
          Spacer()
        }
        .font(.caption).foregroundStyle(.secondary).padding(8)
        Divider()
        LocalShellView(session: session, scheme: scheme, fontSize: fontSize)
      }
    }
  }

  private struct LocalShellView: NSViewRepresentable {
    let session: LocalShellSession
    let scheme: ColorScheme
    let fontSize: CGFloat

    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
      if abs(view.font.pointSize - fontSize) > 0.01 {
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
      }
      let palette = WorkspacePalette(scheme: scheme)
      view.nativeBackgroundColor = NSColor(palette.terminal)
      view.nativeForegroundColor = NSColor(palette.terminalText)
      view.caretColor = NSColor(palette.terminalText)
      view.needsDisplay = true
    }
  }
#endif
