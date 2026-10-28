import SwiftTerm
import SwiftUI

/// One native terminal per live session preserves its screen when tabs change.
@MainActor
final class TerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
  let view: TerminalView
  private weak var session: TerminalSession?

  init(session: TerminalSession) {
    self.session = session
    view = FocusedTerminalView(
      frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    super.init()
    view.changeScrollback(5000)
    #if os(iOS)
      // The localized SwiftUI key bar owns modifiers; do not install two bars
      // whose separate Ctrl states can override one another.
      view.inputAccessoryView = nil
    #endif
    view.terminalDelegate = self
    (view as? FocusedTerminalView)?.onFocus = { [weak session] in session?.onFocus?() }
    #if os(macOS)
      // SwiftTerm's AppKit view is not an AX element by default. Expose the
      // input surface without publishing remote terminal contents as AX values.
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.textArea)
      view.setAccessibilityIdentifier("sshTerminal")
    #endif
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    session?.resize(columns: newCols, rows: newRows)
  }
  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    session?.send(Array(data))
  }
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  // Remote escape sequences cannot silently open links or access the clipboard.
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func clipboardCopy(source: TerminalView, content: Data) {}
  func clipboardRead(source: TerminalView) -> Data? { nil }
  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
  func bell(source: TerminalView) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

enum TerminalInput {
  static func arrow(_ symbol: String, applicationCursor: Bool) -> [UInt8] {
    let suffix: UInt8
    switch symbol {
    case "arrow.up": suffix = 65
    case "arrow.down": suffix = 66
    case "arrow.right": suffix = 67
    case "arrow.left": suffix = 68
    default: return []
    }
    return [27, applicationCursor ? 79 : 91, suffix]
  }
}

struct NativeTerminalView {
  let scheme: ColorScheme
  let accessibilityText: String
  var session: TerminalSession?
  var fontSize: CGFloat = 13
}

#if os(macOS)
  import AppKit

  extension NativeTerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
      session?.surface.view
        ?? TerminalView(
          frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    func updateNSView(_ view: TerminalView, context: Context) {
      if abs(view.font.pointSize - fontSize) > 0.01 {
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
      }
      let palette = WorkspacePalette(scheme: scheme)
      view.nativeBackgroundColor = NSColor(palette.terminal)
      view.nativeForegroundColor = NSColor(palette.terminalText)
      view.caretColor = NSColor(
        session?.isConnected == true ? palette.terminalText : palette.terminal)
      view.setAccessibilityLabel(accessibilityText)
      view.setAccessibilityEnabled(session?.isConnected == true)
      view.needsDisplay = true
    }
  }
#else
  import UIKit

  extension NativeTerminalView: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView {
      session?.surface.view
        ?? TerminalView(
          frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    func updateUIView(_ view: TerminalView, context: Context) {
      if abs(view.font.pointSize - fontSize) > 0.01 {
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
      }
      let palette = WorkspacePalette(scheme: scheme)
      view.nativeBackgroundColor = UIColor(palette.terminal)
      view.nativeForegroundColor = UIColor(palette.terminalText)
      view.caretColor = UIColor(
        session?.isConnected == true ? palette.terminalText : palette.terminal)
      view.isUserInteractionEnabled = session != nil
      view.accessibilityLabel = accessibilityText
      view.keyboardAppearance = scheme == .dark ? .dark : .light
      view.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
      view.setNeedsDisplay()
    }
  }
#endif
