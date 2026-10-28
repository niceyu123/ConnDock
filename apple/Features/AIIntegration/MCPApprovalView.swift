#if os(macOS)
  import AppKit
  import SwiftUI

  @MainActor
  final class MCPApprovalPresenter: NSObject, NSWindowDelegate {
    private weak var service: MCPService?
    private let preferences: AppPreferences
    private var panel: NSPanel?
    private var displayedID: UUID?
    init(service: MCPService, preferences: AppPreferences) {
      self.service = service
      self.preferences = preferences
    }
    func update() {
      guard let service else {
        panel?.orderOut(nil)
        panel?.contentView = nil
        return
      }
      guard let approval = service.approvals.first else {
        displayedID = nil
        panel?.orderOut(nil)
        return
      }
      if displayedID == approval.id { return }
      displayedID = approval.id
      let panel: NSPanel
      if let existing = self.panel {
        panel = existing
      } else {
        panel = NSPanel(
          contentRect: NSRect(x: 0, y: 0, width: 690, height: 620),
          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.minSize = NSSize(width: 620, height: 560)
        self.panel = panel
      }
      panel.title = preferences.text("mcp.approval.title")
      panel.contentView = NSHostingView(
        rootView: MCPApprovalView(approval: approval, service: service).environment(preferences))
      panel.center()
      panel.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if let displayedID { service?.resolveApproval(displayedID, allow: false) }
      return false
    }
  }

  private struct MCPApprovalView: View {
    @Environment(AppPreferences.self) private var preferences
    let approval: MCPApproval
    let service: MCPService
    @State private var reviewed = false
    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Label(preferences.text("mcp.approval.title"), systemImage: "exclamationmark.shield")
          .font(.title2.weight(.semibold))
        Copy("mcp.approval.detail").foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
          row("mcp.approval.host", approval.target.title)
          row("mcp.approval.address", "\(approval.target.host):\(approval.target.port)")
          row("mcp.approval.username", approval.target.username)
          row("mcp.approval.source", "conndock-mcp (PID \(approval.source.pid))")
          GridRow {
            Copy("mcp.approval.timeout").foregroundStyle(.secondary)
            Text(approval.timeout, format: .number).monospacedDigit()
          }
          row("mcp.approval.output", preferences.text("mcp.approval.outputLimit"))
        }
        Copy("mcp.approval.command").font(.headline)
        ScrollView([.vertical, .horizontal]) {
          Text(verbatim: approval.command)
            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .accessibilityIdentifier("mcpExactCommand")
        }
        .frame(minHeight: 150, maxHeight: .infinity)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        Copy("mcp.approval.warning").font(.callout).foregroundStyle(.secondary)
        Toggle(preferences.text("mcp.approval.reviewed"), isOn: $reviewed)
          .accessibilityIdentifier("mcpReviewed")
        HStack {
          Copy("mcp.approval.expires").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(preferences.text("mcp.approval.deny")) {
            service.resolveApproval(approval.id, allow: false)
          }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("mcpDeny")
          Button(preferences.text("mcp.approval.allow")) {
            service.resolveApproval(approval.id, allow: true)
          }
          .disabled(!reviewed).accessibilityIdentifier("mcpAllow")
        }
      }
      .padding(24)
      .environment(\.locale, preferences.language.locale)
      .preferredColorScheme(preferences.appearance.colorScheme)
    }
    private func row(_ key: String, _ value: String) -> some View {
      GridRow {
        Copy(key).foregroundStyle(.secondary)
        Text(verbatim: value).textSelection(.enabled)
      }
    }
  }
#endif
