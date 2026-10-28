#if os(macOS)
  import AppKit
  import SwiftUI

  struct ResizableDivider: View {
    static let handleThickness: CGFloat = 6

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Binding var dimension: Double
    let axis: Axis
    let range: ClosedRange<Double>
    var direction: Double = 1
    let labelKey: String

    var body: some View {
      NativeResizeHandle(
        dimension: $dimension, axis: axis, range: range, direction: direction,
        title: preferences.text(labelKey), identifier: labelKey,
        color: NSColor(WorkspacePalette(scheme: scheme).border)
      )
      .frame(
        width: axis == .horizontal ? Self.handleThickness : nil,
        height: axis == .vertical ? Self.handleThickness : nil)
    }
  }

  private struct NativeResizeHandle: NSViewRepresentable {
    @Binding var dimension: Double
    let axis: Axis
    let range: ClosedRange<Double>
    let direction: Double
    let title: String
    let identifier: String
    let color: NSColor

    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
      view.dimension = dimension
      view.axis = axis
      view.range = range
      view.direction = direction
      view.lineColor = color
      view.onResize = { dimension = $0 }
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.splitter)
      view.setAccessibilityLabel(title)
      view.setAccessibilityIdentifier(identifier)
      view.setAccessibilityValue(dimension.formatted(.number.precision(.fractionLength(0))))
      view.needsDisplay = true
      view.window?.invalidateCursorRects(for: view)
    }
  }

  /// Accept the first mouse-down even in an inactive window, and keep coordinates
  /// in the window while the divider itself moves.
  private final class ResizeHandleView: NSView {
    var dimension: Double = 0
    var axis: Axis = .horizontal
    var range: ClosedRange<Double> = 0...0
    var direction: Double = 1
    var lineColor: NSColor = .separatorColor
    var onResize: ((Double) -> Void)?
    private var startPoint = NSPoint.zero
    private var startDimension: Double = 0

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
      lineColor.setFill()
      let line =
        axis == .horizontal
        ? NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height)
        : NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1)
      NSBezierPath(rect: line).fill()
    }

    override func mouseDown(with event: NSEvent) {
      startPoint = event.locationInWindow
      startDimension = dimension
      window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
      let point = event.locationInWindow
      let delta = axis == .horizontal ? point.x - startPoint.x : startPoint.y - point.y
      resize(to: startDimension + delta * direction)
    }

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 123, 125: resize(to: dimension - 20)
      case 124, 126: resize(to: dimension + 20)
      default: super.keyDown(with: event)
      }
    }

    override func accessibilityPerformIncrement() -> Bool {
      resize(to: dimension + 20)
      return true
    }

    override func accessibilityPerformDecrement() -> Bool {
      resize(to: dimension - 20)
      return true
    }

    private func resize(to proposed: Double) {
      onResize?(min(range.upperBound, max(range.lowerBound, proposed)))
    }
  }
#endif
