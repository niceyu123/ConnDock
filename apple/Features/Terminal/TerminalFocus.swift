import SwiftTerm

#if os(macOS)
  import AppKit

  /// SwiftTerm's macOS becomeFirstResponder override is not open. Observe the
  /// window's native responder updates instead of replacing that implementation.
  @MainActor
  private final class TerminalFocusObserver {
    weak var view: NSView?
    var onFocus: (() -> Void)?
    private var wasFocused = false

    init(view: NSView) {
      self.view = view
      NotificationCenter.default.addObserver(
        self, selector: #selector(updated(_:)), name: NSWindow.didUpdateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func updated(_ notification: Notification) {
      guard let view, let window = view.window,
        notification.object as? NSWindow === window
      else { return }
      let focused = window.firstResponder === view
      if focused && !wasFocused { onFocus?() }
      wasFocused = focused
    }
  }

  final class FocusedTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onWindowAttachment: (() -> Void)?
    private lazy var focusObserver: TerminalFocusObserver = {
      let observer = TerminalFocusObserver(view: self)
      observer.onFocus = { [weak self] in self?.onFocus?() }
      return observer
    }()

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      _ = focusObserver
      if window != nil { onWindowAttachment?() }
    }

    override func mouseDown(with event: NSEvent) {
      onFocus?()
      super.mouseDown(with: event)
    }
  }

  final class FocusedLocalTerminalView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    var onWindowAttachment: (() -> Void)?
    private lazy var focusObserver: TerminalFocusObserver = {
      let observer = TerminalFocusObserver(view: self)
      observer.onFocus = { [weak self] in self?.onFocus?() }
      return observer
    }()

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      _ = focusObserver
      if window != nil { onWindowAttachment?() }
    }

    override func mouseDown(with event: NSEvent) {
      onFocus?()
      super.mouseDown(with: event)
    }
  }
#else
  final class FocusedTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted { onFocus?() }
      return accepted
    }
  }
#endif
