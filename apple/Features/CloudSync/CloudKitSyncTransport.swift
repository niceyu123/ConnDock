import CloudKit
import CryptoKit
import Foundation

/// Real CloudKit transport. No credentials, content logs or SwiftData automatic mirroring.
@MainActor
final class CloudKitSyncTransport: CloudSyncTransport, CKSyncEngineDelegate {
  private let container: CKContainer
  private var engine: CKSyncEngine?
  private var handlers: SyncTransportHandlers?
  private var verifiedAccount: String?
  private var cycleFailure: CloudSyncFailure?

  init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }

  func accountIdentifier() async throws -> String {
    switch try await container.accountStatus() {
    case .available: break
    case .restricted: throw CloudSyncFailure.restricted
    case .noAccount: throw CloudSyncFailure.signedOut
    case .couldNotDetermine, .temporarilyUnavailable: throw CloudSyncFailure.network
    @unknown default: throw CloudSyncFailure.server
    }
    let id = try await container.userRecordID()
    let account = Self.accountFingerprint(id)
    verifiedAccount = account
    return account
  }

  private static func accountFingerprint(_ id: CKRecord.ID) -> String {
    SHA256.hash(data: Data(id.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func start(state: Data?, handlers: SyncTransportHandlers) throws {
    guard verifiedAccount != nil else { throw CloudSyncFailure.signedOut }
    stop()
    self.handlers = handlers
    cycleFailure = nil
    let serialization = try state.map {
      try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    var configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self)
    // Foreground fetch-before-send ensures deleted zones/accounts are checked before uploads.
    configuration.automaticallySync = false
    engine = CKSyncEngine(configuration)
  }

  func enqueue(_ identities: [SyncIdentity]) {
    engine?.state.add(
      pendingRecordZoneChanges: identities.map {
        .saveRecord(CKRecord.ID(recordName: $0.recordName, zoneID: CloudKitRecordCodec.zoneID))
      })
  }

  func synchronize() async throws {
    guard let engine else { throw CloudSyncFailure.cancelled }
    do {
      // A deleted-zone event may be unavailable after a long offline/token reset.
      // Never silently recreate an acknowledged cloud copy in that case.
      do {
        _ = try await container.privateCloudDatabase.recordZone(for: CloudKitRecordCodec.zoneID)
      } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
        if handlers?.expectsExistingZone == true { throw CloudSyncFailure.zoneRemoved }
      }
      guard self.engine === engine, !Task.isCancelled else { throw CloudSyncFailure.cancelled }
      try await engine.fetchChanges()
      if let cycleFailure { throw cycleFailure }
      guard self.engine === engine, !Task.isCancelled else { throw CloudSyncFailure.cancelled }
      engine.state.add(pendingDatabaseChanges: [
        .saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))
      ])
      try await engine.sendChanges()
      if let cycleFailure { throw cycleFailure }
    } catch {
      throw cycleFailure ?? cloudSyncFailure(error)
    }
  }

  func stop() {
    let previous = engine
    engine = nil
    handlers = nil
    // A delegate can stop its own engine. Awaiting cancellation there would deadlock.
    if let previous { Task { await previous.cancelOperations() } }
  }

  func deleteZone() async throws {
    do {
      _ = try await container.privateCloudDatabase.deleteRecordZone(
        withID: CloudKitRecordCodec.zoneID)
    } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
      return
    }
  }

  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await handle(event, engine: syncEngine)
  }

  private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
    guard self.engine === engine, let handlers else { return }
    do {
      switch event {
      case .stateUpdate(let update):
        try await handlers.event(.state(JSONEncoder().encode(update.stateSerialization)))
      case .accountChange(let account):
        switch account.changeType {
        case .signIn(let id) where Self.accountFingerprint(id) == verifiedAccount: break
        default: try await handlers.event(.accountChanged)
        }
      case .fetchedDatabaseChanges(let changes):
        if changes.deletions.contains(where: { $0.zoneID == CloudKitRecordCodec.zoneID }) {
          try await handlers.event(.zoneRemoved)
        }
      case .fetchedRecordZoneChanges(let changes):
        let modifications = changes.modifications.filter {
          $0.record.recordID.zoneID == CloudKitRecordCodec.zoneID
        }
        for offset in stride(from: 0, to: modifications.count, by: 200) {
          let records = try modifications[offset..<min(offset + 200, modifications.count)].map {
            try CloudKitRecordCodec.snapshot(from: $0.record)
          }
          try await handlers.event(.records(records))
        }
        let deleted = try changes.deletions.filter {
          $0.recordID.zoneID == CloudKitRecordCodec.zoneID
        }.map {
          guard let id = SyncIdentity(recordName: $0.recordID.recordName) else {
            throw CloudSyncFailure.invalidRecord
          }
          return id
        }
        for offset in stride(from: 0, to: deleted.count, by: 200) {
          try await handlers.event(
            .deleted(Array(deleted[offset..<min(offset + 200, deleted.count)])))
        }
      case .sentRecordZoneChanges(let changes):
        if !changes.savedRecords.isEmpty {
          try await handlers.event(
            .records(changes.savedRecords.map { try CloudKitRecordCodec.snapshot(from: $0) }))
        }
        for failed in changes.failedRecordSaves {
          switch failed.error.code {
          case .serverRecordChanged:
            guard let server = failed.error.serverRecord else { throw CloudSyncFailure.server }
            try await handlers.event(.records([CloudKitRecordCodec.snapshot(from: server)]))
          case .unknownItem:
            guard let id = SyncIdentity(recordName: failed.record.recordID.recordName) else {
              throw CloudSyncFailure.invalidRecord
            }
            try await handlers.event(.deleted([id]))
          case .batchRequestFailed:
            // The durable outbox retains records rejected with another batch failure.
            break
          default: throw cloudSyncFailure(failed.error)
          }
        }
      case .sentDatabaseChanges(let changes):
        if let failed = changes.failedZoneSaves.first { throw cloudSyncFailure(failed.error) }
      case .didFetchRecordZoneChanges(let changes):
        if let error = changes.error { throw cloudSyncFailure(error) }
      default: break
      }
    } catch {
      cycleFailure = cloudSyncFailure(error)
      stop()
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await batch(context, engine: syncEngine)
  }

  private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async
    -> CKSyncEngine.RecordZoneChangeBatch?
  {
    guard self.engine === engine, let handlers else { return nil }
    do {
      let changes = Array(
        engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }.prefix(
          200))
      let names = changes.compactMap { change -> String? in
        guard case .saveRecord(let id) = change else { return nil }
        return id.recordName
      }
      let snapshots = try handlers.records(names)
      let included = Set(snapshots.map { $0.document.identity.recordName })
      let obsolete = changes.filter { change in
        guard case .saveRecord(let id) = change else { return true }
        return !included.contains(id.recordName)
      }
      engine.state.remove(pendingRecordZoneChanges: obsolete)
      let records = try snapshots.map { try CloudKitRecordCodec.record(from: $0) }
      guard !records.isEmpty else { return nil }
      return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    } catch {
      cycleFailure = cloudSyncFailure(error)
      stop()
      return nil
    }
  }
}
