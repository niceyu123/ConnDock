import Foundation
import Observation

@MainActor @Observable
final class CloudSyncService {
  private(set) var isEnabled = false
  private(set) var isSyncing = false
  private(set) var pendingCount = 0
  private(set) var lastSync: Date?
  private(set) var failure: CloudSyncFailure?
  private(set) var nextRetryAt: Date?
  private(set) var isForeground = true
  private(set) var cloudCopyDeleted = false
  let isConfigured: Bool
  @ObservationIgnored private let library: HostLibrary
  @ObservationIgnored private let factory: () throws -> any CloudSyncTransport
  @ObservationIgnored private var transport: (any CloudSyncTransport)?
  @ObservationIgnored private var operation: Task<Void, Error>?
  @ObservationIgnored private var scheduled: Task<Void, Never>?
  @ObservationIgnored private var epoch = UUID()
  @ObservationIgnored private var failures = 0

  init(library: HostLibrary, factory: (() throws -> any CloudSyncTransport)? = nil) {
    self.library = library
    let configuration = CloudSyncConfiguration.current
    isConfigured = factory != nil || configuration.isConfigured
    self.factory =
      factory ?? {
        guard let identifier = configuration.containerIdentifier else {
          throw CloudSyncFailure.configuration
        }
        return CloudKitSyncTransport(containerIdentifier: identifier)
      }
    if let settings = try? library.syncSettings() {
      isEnabled = settings.enabled && isConfigured
      lastSync = settings.lastSync
    }
    library.onSyncChange = { [weak self] in self?.localChanges() }
    refreshCount()
  }

  var statusKey: String {
    if !isConfigured { return "cloud.status.unconfigured" }
    if let failure { return failure.localizationKey }
    if isSyncing { return "cloud.status.syncing" }
    if !isEnabled { return "cloud.status.disabled" }
    if !isForeground { return "cloud.status.paused" }
    return pendingCount > 0 ? "cloud.status.pending" : "cloud.status.current"
  }

  func enable() async {
    guard isConfigured else {
      failure = .configuration
      return
    }
    guard !isSyncing else { return }
    let token = UUID()
    epoch = token
    isSyncing = true
    cloudCopyDeleted = false
    do {
      let candidate = try factory()
      let account = try await candidate.accountIdentifier()
      try requireCurrent(token, requireEnabled: false)
      let settings = try library.syncSettings()
      try library.configureSync(
        enabled: true, account: account, resetRemote: settings.account != account)
      isEnabled = true
      failure = nil
      refreshCount()
    } catch {
      if epoch == token { failure = cloudSyncFailure(error) }
    }
    guard epoch == token else { return }
    isSyncing = false
    if isEnabled { await syncNow() }
  }

  func disable() { pause(reason: nil, resetRemote: false) }

  private func pause(reason: CloudSyncFailure?, resetRemote: Bool) {
    epoch = UUID()
    scheduled?.cancel()
    scheduled = nil
    operation?.cancel()
    operation = nil
    transport?.stop()
    transport = nil
    isSyncing = false
    isEnabled = false
    nextRetryAt = nil
    failure = reason
    do { try library.configureSync(enabled: false, resetRemote: resetRemote) } catch {
      failure = .localStore
    }
    refreshCount()
  }

  func setForeground(_ foreground: Bool) {
    guard isForeground != foreground else { return }
    isForeground = foreground
    if foreground {
      if isEnabled { schedule(after: 0) }
    } else {
      epoch = UUID()
      scheduled?.cancel()
      scheduled = nil
      operation?.cancel()
      operation = nil
      transport?.stop()
      transport = nil
      isSyncing = false
      nextRetryAt = nil
    }
  }

  func resume() {
    if isEnabled, isForeground { schedule(after: 0) }
  }

  func syncNow() async {
    guard isEnabled, isForeground, !isSyncing else { return }
    scheduled?.cancel()
    scheduled = nil
    let token = UUID()
    epoch = token
    isSyncing = true
    failure = nil
    nextRetryAt = nil
    let work = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      try await self.synchronize(token: token)
    }
    operation = work
    do {
      try await work.value
      try requireCurrent(token)
      refreshCount()
      if pendingCount == 0 {
        try library.markSyncSuccessful()
        lastSync = try library.syncSettings().lastSync
      }
      failures = 0
    } catch {
      guard epoch == token else { return }
      let mapped = cloudSyncFailure(error)
      if mapped == .accountChanged || mapped == .zoneRemoved || mapped == .signedOut {
        pause(reason: mapped, resetRemote: true)
        return
      }
      failure = mapped
      failures = min(failures + 1, 6)
    }
    guard epoch == token else { return }
    transport?.stop()
    transport = nil
    operation = nil
    isSyncing = false
    refreshCount()
    if let failure {
      if [.network, .server, .quota, .cancelled].contains(failure) {
        let delay = min(300.0, 5.0 * pow(2.0, Double(failures - 1)))
        nextRetryAt = Date().addingTimeInterval(delay)
        schedule(after: delay)
      }
    } else {
      schedule(after: pendingCount == 0 ? 60 : 1)
    }
  }

  private func synchronize(token: UUID) async throws {
    let candidate = try factory()
    transport = candidate
    let account = try await candidate.accountIdentifier()
    try requireCurrent(token)
    let settings = try library.syncSettings()
    guard settings.account == account else { throw CloudSyncFailure.accountChanged }
    let currentRecords = try library.syncRecords()
    let handlers = SyncTransportHandlers(
      records: { [weak self] names in
        guard let self else { throw CloudSyncFailure.cancelled }
        try self.requireCurrent(token)
        let requested = Set(names)
        return try self.library.syncRecords(pendingOnly: true).filter {
          requested.contains($0.document.identity.recordName)
        }
      },
      event: { [weak self] event in
        guard let self else { throw CloudSyncFailure.cancelled }
        try await self.receive(event, token: token)
      },
      expectsExistingZone: settings.lastSync != nil
        || currentRecords.contains { $0.systemFields != nil })
    try candidate.start(state: settings.engineState, handlers: handlers)
    candidate.enqueue(try library.syncRecords(pendingOnly: true).map(\.document.identity))
    try await candidate.synchronize()
    try requireCurrent(token)
  }

  private func receive(_ event: SyncTransportEvent, token: UUID) async throws {
    try requireCurrent(token)
    // Keychain work can temporarily own the library. Wait without advancing the engine token.
    let deadline = Date().addingTimeInterval(10)
    while library.isBusy {
      guard Date() < deadline else { throw CloudSyncFailure.localStore }
      try await Task.sleep(for: .milliseconds(50))
      try requireCurrent(token)
    }
    switch event {
    case .state(let data): try library.persistSyncEngineState(data)
    case .records(let records): try await library.applySyncRecords(records)
    case .deleted(let identities): try await library.applySyncDeletions(identities)
    case .accountChanged: throw CloudSyncFailure.accountChanged
    case .zoneRemoved: throw CloudSyncFailure.zoneRemoved
    }
    try requireCurrent(token)
    refreshCount()
    if case .records = event {
      transport?.enqueue(try library.syncRecords(pendingOnly: true).map(\.document.identity))
    }
    if case .deleted = event {
      transport?.enqueue(try library.syncRecords(pendingOnly: true).map(\.document.identity))
    }
  }

  private func requireCurrent(_ token: UUID, requireEnabled: Bool = true) throws {
    guard epoch == token, !Task.isCancelled, isForeground, !requireEnabled || isEnabled else {
      throw CloudSyncFailure.cancelled
    }
  }

  private func refreshCount() {
    do { pendingCount = try library.syncRecords(pendingOnly: true).count } catch {
      failure = .localStore
    }
  }

  private func localChanges() {
    refreshCount()
    if isEnabled, isForeground, !isSyncing { schedule(after: 1) }
  }

  private func schedule(after seconds: Double) {
    scheduled?.cancel()
    scheduled = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.scheduled = nil
      await self?.syncNow()
    }
  }

  /// UI supplies a separate destructive confirmation before calling this method.
  func deleteCloudCopy() async {
    guard isConfigured else {
      failure = .configuration
      return
    }
    let expected = try? library.syncSettings().account
    guard let expected else {
      failure = .signedOut
      return
    }
    pause(reason: nil, resetRemote: false)
    let token = UUID()
    epoch = token
    isSyncing = true
    do {
      let candidate = try factory()
      guard try await candidate.accountIdentifier() == expected else {
        throw CloudSyncFailure.accountChanged
      }
      try requireCurrent(token, requireEnabled: false)
      try await candidate.deleteZone()
      try requireCurrent(token, requireEnabled: false)
      try library.configureSync(enabled: false, resetRemote: true)
      lastSync = nil
      cloudCopyDeleted = true
    } catch { if epoch == token { failure = cloudSyncFailure(error) } }
    if epoch == token {
      isSyncing = false
      refreshCount()
    }
  }
}
