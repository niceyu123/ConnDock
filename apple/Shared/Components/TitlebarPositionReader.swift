#if os(macOS)
  import AppKit
  import SwiftUI

  /// Toolbar and content have separate hosting views. Measure in window
  /// coordinates so alignment does not depend on toolbar centering or padding.
  struct TitlebarPositionReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> TitlebarAnchorView { TitlebarAnchorView() }

    func updateNSView(_ view: TitlebarAnchorView, context: Context) {
      view.onChange = onChange
      view.needsLayout = true
    }
  }

  final class TitlebarAnchorView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var reportedX: CGFloat?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // The sidebar already carries the app name; leave this space for tabs.
      window?.titleVisibility = .hidden
      needsLayout = true
    }

    override func layout() {
      super.layout()
      guard window != nil else { return }
      let origin = convert(bounds, to: nil).minX
      guard origin.isFinite, reportedX.map({ abs($0 - origin) > 0.5 }) ?? true else { return }
      reportedX = origin
      let callback = onChange
      DispatchQueue.main.async { callback?(origin) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif
