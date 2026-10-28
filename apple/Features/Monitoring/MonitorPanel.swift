import Charts
import SSHCoreBridge
import SwiftUI

struct MonitorPanel: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    let session = workspace.selectedSession
    let target =
      session?.target ?? workspace.selectedHostID.flatMap { workspace.library?.host($0)?.target }

    VStack(alignment: .leading, spacing: 10) {
      HStack {
        HStack(spacing: 5) {
          Image(systemName: "macwindow").font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(preferences.text("monitor.inspector"))
            .font(.subheadline.weight(.semibold))
        }
        Spacer()
        #if os(macOS)
          IconButton(key: "layout.hideInspector", symbol: "chevron.right") {
            withAnimation(.easeInOut(duration: 0.2)) {
              preferences.inspectorVisible = false
            }
          }
          .buttonStyle(.plain).font(.caption)
          .accessibilityIdentifier("monitor.hideInspector")
        #endif
      }

      VStack(spacing: 5) {
        compactInfoRow("monitor.host", value: target.map { "\($0.host):\($0.port)" })
        compactInfoRow("monitor.os", value: session?.monitor?.latest?.system)
        compactInfoRow(
          "monitor.uptime", value: session?.monitor?.latest.map { uptime($0.uptimeSeconds) })
        HStack {
          Copy("monitor.latency").foregroundStyle(.secondary)
          Spacer()
          if session?.isConnected == true {
            HStack(spacing: 3) {
              Circle().fill(Color.green).frame(width: 6, height: 6)
              Text(verbatim: "18 ms")
            }
            .foregroundStyle(.green)
          } else {
            Text(verbatim: "--").foregroundStyle(.secondary)
          }
        }
        .font(.caption)
      }
      .padding(8)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))

      Divider().padding(.vertical, 2)

      if let session, let model = session.monitor {
        LiveMonitorContent(model: model).id(session.id)
      } else {
        HStack {
          Text(preferences.text("monitor.resources")).font(.subheadline.weight(.semibold))
          Spacer()
        }
        VStack(spacing: 8) {
          compactPlaceholder("monitor.cpu", symbol: "cpu", color: .blue, palette: palette)
          compactPlaceholder(
            "monitor.memory", symbol: "memorychip", color: .purple, palette: palette)
          compactPlaceholder(
            "monitor.disk", symbol: "internaldrive", color: .green, palette: palette)
          compactNetworkPlaceholder(palette: palette)
        }
        Copy("monitor.connectToCollect").font(.caption2).foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(palette.panel)
  }

  private func uptime(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = preferences.language.locale
    formatter.calendar = calendar
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: seconds) ?? preferences.text("common.unavailable")
  }

  private func compactInfoRow(_ key: String, value: String? = nil) -> some View {
    HStack {
      Copy(key).foregroundStyle(.secondary)
      Spacer()
      if let value {
        Text(verbatim: value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      } else {
        Text(verbatim: "--").foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }

  private func compactPlaceholder(
    _ key: String, symbol: String, color: Color, palette: WorkspacePalette
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        HStack(spacing: 4) {
          Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
          Copy(key).font(.caption.weight(.medium))
        }
        Spacer()
        Text(verbatim: "--").font(.caption).foregroundStyle(.secondary)
      }
      Capsule().fill(palette.panel).frame(height: 6)
    }
    .padding(8)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
  }

  private func compactNetworkPlaceholder(palette: WorkspacePalette) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        HStack(spacing: 4) {
          Image(systemName: "network").foregroundStyle(.cyan).accessibilityHidden(true)
          Copy("monitor.network").font(.caption.weight(.medium))
        }
        Spacer()
        Text(verbatim: "--").font(.caption2).foregroundStyle(.secondary)
      }
      HStack(spacing: 4) {
        HStack(spacing: 2) {
          Image(systemName: "arrow.up").font(.system(size: 8)).foregroundStyle(.orange)
          Text(verbatim: "--").lineLimit(1)
        }
        .font(.system(size: 10).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 4))

        HStack(spacing: 2) {
          Image(systemName: "arrow.down").font(.system(size: 8)).foregroundStyle(.cyan)
          Text(verbatim: "--").lineLimit(1)
        }
        .font(.system(size: 10).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 4))
      }
    }
    .padding(8)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
  }
}

private enum MetricKind: String, CaseIterable {
  case cpu, memory, disk, network
  var key: String { "monitor.\(rawValue)" }
  var symbol: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    }
  }
  var color: Color {
    switch self {
    case .cpu: .blue
    case .memory: .purple
    case .disk: .green
    case .network: .cyan
    }
  }
  func value(_ metrics: ServerMetrics) -> Double? {
    switch self {
    case .cpu: metrics.cpuPercent
    case .memory:
      metrics.memoryTotal == 0
        ? nil : Double(metrics.memoryUsed) / Double(metrics.memoryTotal) * 100
    case .disk: metrics.diskPercent
    case .network: metrics.receiveBytesPerSecond
    }
  }
}

private struct LiveMonitorContent: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(\.colorScheme) private var scheme
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var model: ServerMonitorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(preferences.text("monitor.resources")).font(.subheadline.weight(.semibold))
        Spacer()
        IconButton(
          key: model.isPaused ? "monitor.resume" : "monitor.pause",
          symbol: model.isPaused ? "play.circle" : "pause.circle"
        ) { model.togglePaused() }
        .buttonStyle(.plain).font(.caption2).accessibilityIdentifier("monitor.togglePause")
      }
      if let error = model.errorKey {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Copy(error).font(.caption2).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button(preferences.text("action.retry")) { model.retry() }.font(.caption2)
        }
        .accessibilityIdentifier("monitor.error")
      }
      if model.isCollecting && model.latest == nil {
        ProgressView(preferences.text("monitor.sampling")).font(.caption2).controlSize(.mini)
      }
      ForEach(MetricKind.allCases, id: \.rawValue) { kind in card(kind) }
      if let sampledAt = model.sampledAt {
        HStack {
          Copy("monitor.lastSample")
          Text(
            sampledAt,
            format: .dateTime.hour().minute().second().locale(preferences.language.locale))
        }.font(.caption2).foregroundStyle(.secondary)
      }
    }
    .onAppear {
      model.setForeground(scenePhase == .active)
      model.setVisible(true)
    }
    .onDisappear { model.setVisible(false) }
    .onChange(of: scenePhase) { _, value in model.setForeground(value == .active) }
  }

  private func card(_ kind: MetricKind) -> some View {
    let palette = WorkspacePalette(scheme: scheme)
    return VStack(alignment: .leading, spacing: 5) {
      HStack {
        HStack(spacing: 4) {
          Image(systemName: kind.symbol).foregroundStyle(kind.color).accessibilityHidden(true)
          Copy(kind.key).font(.caption.weight(.medium))
        }
        Spacer()
        if kind == .network {
          Text(verbatim: "eth0").font(.caption2).foregroundStyle(.secondary)
        } else if let metrics = model.latest, let value = kind.value(metrics) {
          if kind == .memory {
            capacityCompact(used: metrics.memoryUsed, total: metrics.memoryTotal, color: kind.color)
          } else if kind == .disk {
            capacityCompact(used: metrics.diskUsed, total: metrics.diskTotal, color: kind.color)
          } else {
            Text(
              value / 100,
              format: .percent.precision(.fractionLength(0...1)).locale(preferences.language.locale)
            )
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(kind.color)
            .accessibilityIdentifier("monitor.value.\(kind.rawValue)")
          }
        } else {
          Text(verbatim: "--").font(.caption).foregroundStyle(.secondary)
        }
      }
      if kind == .network {
        HStack(spacing: 4) {
          HStack(spacing: 2) {
            Image(systemName: "arrow.up").font(.system(size: 8)).foregroundStyle(.orange)
            Text(verbatim: rate(model.latest?.transmitBytesPerSecond)).lineLimit(1)
          }
          .font(.system(size: 10).monospacedDigit())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4).padding(.vertical, 2)
          .background(palette.panel, in: RoundedRectangle(cornerRadius: 4))

          HStack(spacing: 2) {
            Image(systemName: "arrow.down").font(.system(size: 8)).foregroundStyle(.cyan)
            Text(verbatim: rate(model.latest?.receiveBytesPerSecond)).lineLimit(1)
          }
          .font(.system(size: 10).monospacedDigit())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4).padding(.vertical, 2)
          .background(palette.panel, in: RoundedRectangle(cornerRadius: 4))
        }
      } else {
        let fraction: Double = {
          guard let metrics = model.latest, let val = kind.value(metrics) else { return 0 }
          return max(0, min(1, val / 100.0))
        }()
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(palette.panel)
            Capsule().fill(kind.color)
              .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(fraction))))
          }
        }
        .frame(height: 6)
      }
    }
    .padding(8).background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
  }

  private func capacityCompact(used: UInt64, total: UInt64, color: Color) -> some View {
    let usedGb = Double(used) / 1_073_741_824.0
    let totalGb = Double(total) / 1_073_741_824.0
    return Text(
      verbatim: String(format: "%.1f / %.1f GB", usedGb, totalGb)
    )
    .font(.caption.weight(.semibold).monospacedDigit())
    .foregroundStyle(color)
  }

  private func rate(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    let bytes = value >= Double(Int64.max) ? Int64.max : Int64(max(0, value))
    return bytes.formatted(.byteCount(style: .file).locale(preferences.language.locale)) + "/s"
  }
}
