import Foundation
import Observation
import SSHCoreBridge

struct MonitorPoint: Identifiable {
  let id = UUID()
  let date: Date
  let metrics: ServerMetrics
}

@MainActor @Observable
final class ServerMonitorModel {
  private(set) var latest: ServerMetrics?
  private(set) var history: [MonitorPoint] = []
  private(set) var isPaused = false
  private(set) var isCollecting = false
  private(set) var sampledAt: Date?
  private(set) var errorKey: String?
  @ObservationIgnored private let connection: SshConnection
  @ObservationIgnored private var connected = false
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var foreground = true
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var collector: RemoteMonitor?
  @ObservationIgnored private var task: Task<Void, Never>?

  init(connection: SshConnection) { self.connection = connection }

  func setConnected(_ connected: Bool) {
    self.connected = connected
    if connected {
      startIfNeeded()
    } else {
      stopTask()
      latest = nil
      sampledAt = nil
      history = []
    }
  }
  func setVisible(_ visible: Bool) {
    self.visible = visible
    if visible { startIfNeeded() } else { stopTask() }
  }
  func setForeground(_ foreground: Bool) {
    self.foreground = foreground
    if foreground { startIfNeeded() } else { stopTask() }
  }
  func togglePaused() {
    isPaused.toggle()
    if isPaused {
      stopTask()
    } else {
      errorKey = nil
      startIfNeeded()
    }
  }
  func retry() {
    stopTask()
    isPaused = false
    errorKey = nil
    startIfNeeded()
  }
  private func stopTask() {
    generation += 1
    collector?.stop()
    collector = nil
    task?.cancel()
    task = nil
    isCollecting = false
  }
  private func startIfNeeded() {
    guard connected, visible, foreground, !isPaused, task == nil, errorKey == nil else { return }
    let revision = generation
    do {
      let monitor = try connection.startLinuxMonitor()
      collector = monitor
      isCollecting = true
      task = Task { [weak self] in
        defer { monitor.stop() }
        do {
          while !Task.isCancelled {
            guard self != nil else { return }
            let metrics = try await monitor.sample()
            guard !Task.isCancelled, self?.generation == revision else { return }
            self?.accept(metrics)
            try await Task.sleep(for: .seconds(5))
          }
        } catch {
          if !Task.isCancelled, self?.generation == revision {
            self?.errorKey =
              remoteCode(error) == .unsupported ? "monitor.unsupported" : remoteErrorKey(error)
            self?.isCollecting = false
            self?.task = nil
            self?.collector = nil
          }
        }
      }
    } catch {
      errorKey = remoteErrorKey(error)
      isCollecting = false
    }
  }
  private func accept(_ metrics: ServerMetrics) {
    let date = Date()
    latest = metrics
    sampledAt = date
    history.append(MonitorPoint(date: date, metrics: metrics))
    if history.count > 120 { history.removeFirst(history.count - 120) }
  }
}
