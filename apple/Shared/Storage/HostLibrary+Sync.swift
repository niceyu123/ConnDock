import Foundation
import SwiftData

extension HostLibrary {
  private func syncStateRow() throws -> StoredSyncState {
    let rows = try context.fetch(FetchDescriptor<StoredSyncState>())
    guard rows.count == 1, let row = rows.first, row.key == "private-v1" else {
      throw CloudSyncFailure.localStore
    }
    return row
  }

  private func syncRows() throws -> [String: StoredSyncRecord] {
    var result: [String: StoredSyncRecord] = [:]
    for row in try context.fetch(FetchDescriptor<StoredSyncRecord>()) {
      guard result.updateValue(row, forKey: row.recordName) == nil else {
        throw CloudSyncFailure.localStore
      }
    }
    return result
  }

  func prepareSyncStorage() throws {
    let states = try context.fetch(FetchDescriptor<StoredSyncState>())
    if states.isEmpty { context.insert(StoredSyncState()) }
    let existing = try syncRows()
    let hosts = try context.fetch(FetchDescriptor<StoredHost>()).map { SyncIdentity.host($0.id) }
    let groups = try context.fetch(FetchDescriptor<StoredHostGroup>()).map {
      SyncIdentity.group($0.id)
    }
    try stageSyncChanges((hosts + groups).filter { existing[$0.recordName] == nil })
    try context.save()
  }

  /// Called before the same save that commits a local edit: no save/outbox gap.
  func stageSyncChanges(_ identities: [SyncIdentity]) throws {
    guard !identities.isEmpty else { return }
    let state = try syncStateRow()
    var existing = try syncRows()
    let hostRows = try context.fetch(FetchDescriptor<StoredHost>())
    let groupRows = try context.fetch(FetchDescriptor<StoredHostGroup>())
    for identity in Set(identities) {
      guard state.clock < Int64.max - 1 else { throw CloudSyncFailure.localStore }
      state.clock += 1
      let version = SyncVersion(counter: state.clock, device: state.deviceID, mutation: UUID())
      let document: SyncDocument
      switch identity.kind {
      case .host:
        let matching = hostRows.filter { $0.id == identity.id }
        guard matching.count == 1, let row = matching.first else {
          throw CloudSyncFailure.localStore
        }
        var value = SyncedHost(row)
        let connection = try storedConnectionOptions(for: row.id)
        let previousSchema =
          try existing[identity.recordName].map {
            try SyncDocument.decode($0.documentData).schemaVersion
          } ?? 1
        value.connectionOptions = connection.isAdvanced ? connection : nil
        value.tags =
          try context.fetch(FetchDescriptor<StoredHostLabels>()).first { $0.hostID == row.id }?
          .labels ?? []
        document = SyncDocument(
          // Once upgraded, keep v2 even when the user explicitly clears a route.
          // This distinguishes that action from an old client's incomplete edit.
          schemaVersion: connection.isAdvanced || !row.authMethod.needsCredential
            || previousSchema == 2 ? 2 : 1,
          identity: identity, version: version, deleted: row.deletedAt != nil,
          createdAt: row.createdAt, updatedAt: row.updatedAt,
          host: row.deletedAt == nil ? value : nil)
      case .group:
        let matching = groupRows.filter { $0.id == identity.id }
        guard matching.count == 1, let row = matching.first else {
          throw CloudSyncFailure.localStore
        }
        document = SyncDocument(
          identity: identity, version: version, deleted: row.deletedAt != nil,
          createdAt: row.createdAt, updatedAt: row.updatedAt,
          group: row.deletedAt == nil ? SyncedGroup(name: row.name, sortIndex: row.sortIndex) : nil)
      }
      if let row = existing[identity.recordName] {
        row.documentData = try document.encoded()
        row.pending = true
      } else {
        let row = try StoredSyncRecord(document: document)
        context.insert(row)
        existing[identity.recordName] = row
      }
    }
  }

  func syncRecords(pendingOnly: Bool = false) throws -> [SyncRecordSnapshot] {
    try syncRows().values.filter { !pendingOnly || $0.pending }.map {
      let document = try SyncDocument.decode($0.documentData)
      guard document.identity.recordName == $0.recordName else { throw CloudSyncFailure.localStore }
      return SyncRecordSnapshot(
        document: document, systemFields: $0.systemFields, pending: $0.pending)
    }.sorted { $0.document.identity.recordName < $1.document.identity.recordName }
  }

  func syncSettings() throws -> SyncSettings {
    let row = try syncStateRow()
    return SyncSettings(
      enabled: row.enabled, account: row.account, engineState: row.engineState,
      lastSync: row.lastSync)
  }

  func configureSync(enabled: Bool, account: String? = nil, resetRemote: Bool = false) throws {
    // Busy spans only Keychain awaits; row mutation/commit never yields MainActor.
    // Disabling must remain durable during that cleanup, especially on account changes.
    guard !isBusy || !enabled else { throw HostLibraryError.busy }
    let state = try syncStateRow()
    if enabled, account == nil && state.account == nil { throw CloudSyncFailure.signedOut }
    if resetRemote {
      for row in try syncRows().values {
        row.systemFields = nil
        row.pending = true
      }
      state.engineState = nil
      state.lastSync = nil
    }
    if let account { state.account = account }
    state.enabled = enabled
    try commit()
  }

  func persistSyncEngineState(_ data: Data?) throws {
    try syncStateRow().engineState = data
    try commit()
  }

  func markSyncSuccessful() throws {
    try syncStateRow().lastSync = Date()
    try commit()
  }

  /// Merge and durable ACK share one transaction. No networking/Keychain awaits before commit.
  func applySyncRecords(_ incoming: [SyncRecordSnapshot], forcePending: Bool = false) async throws {
    guard incoming.count <= 512 else { throw CloudSyncFailure.invalidRecord }
    for item in incoming { _ = try item.document.encoded() }
    try beginRemoteMerge()
    defer { endRemoteMerge() }
    var retired: [String] = []
    do {
      let state = try syncStateRow()
      var rows = try syncRows()
      var apply: [SyncDocument] = []
      for item in incoming {
        let remote = item.document
        state.clock = max(state.clock, remote.version.counter)
        let name = remote.identity.recordName
        let row: StoredSyncRecord
        let winner: SyncDocument
        if let existing = rows[name] {
          let local = try SyncDocument.decode(existing.documentData)
          winner = try local.wins(over: remote) ? local : remote
          if winner != local { apply.append(winner) }
          row = existing
        } else {
          winner = remote
          row = try StoredSyncRecord(document: winner)
          context.insert(row)
          rows[name] = row
          apply.append(winner)
        }
        row.documentData = try winner.encoded()
        row.systemFields = item.systemFields
        row.pending = winner != remote || forcePending
      }
      let deletedGroups = try Set(
        rows.values.compactMap { row -> UUID? in
          let document = try SyncDocument.decode(row.documentData)
          return document.identity.kind == .group && document.deleted ? document.identity.id : nil
        })
      for document in apply where document.identity.kind == .group { try applyGroup(document) }
      for document in apply where document.identity.kind == .host {
        if let reference = try applyHost(document, deletedGroups: deletedGroups) {
          retired.append(reference)
        }
      }
      // A group tombstone also clears references delivered in an earlier batch.
      for host in try context.fetch(FetchDescriptor<StoredHost>()) {
        if let id = host.groupID, deletedGroups.contains(id) {
          host.groupID = nil
          host.syncRevision += 1
        }
      }
      try commit()
    } catch {
      context.rollback()
      throw error
    }
    for reference in retired { await retire(reference) }
    onSyncChange?()
  }

  func applySyncDeletions(_ identities: [SyncIdentity]) async throws {
    let state = try syncStateRow()
    let rows = try syncRows()
    var counter = state.clock
    var records: [SyncRecordSnapshot] = []
    for identity in Set(identities) {
      guard counter < Int64.max - 1 else { throw CloudSyncFailure.localStore }
      counter += 1
      let old = try rows[identity.recordName].map { try SyncDocument.decode($0.documentData) }
      let document = SyncDocument(
        identity: identity,
        version: SyncVersion(counter: counter, device: state.deviceID, mutation: UUID()),
        deleted: true, createdAt: old?.createdAt ?? Date(), updatedAt: Date())
      records.append(SyncRecordSnapshot(document: document))
    }
    // Publish an address-free tombstone so another offline device cannot resurrect it.
    try await applySyncRecords(records, forcePending: true)
  }

  private func applyGroup(_ document: SyncDocument) throws {
    let matching = try context.fetch(FetchDescriptor<StoredHostGroup>()).filter {
      $0.id == document.identity.id
    }
    guard matching.count <= 1 else { throw CloudSyncFailure.localStore }
    if document.deleted {
      if let row = matching.first {
        row.deletedAt = document.updatedAt
        row.syncRevision += 1
      }
      return
    }
    guard let value = document.group else { throw CloudSyncFailure.invalidRecord }
    let row = matching.first ?? StoredHostGroup(name: value.name)
    if matching.isEmpty {
      row.id = document.identity.id
      context.insert(row)
    }
    row.name = value.name
    row.sortIndex = value.sortIndex
    row.createdAt = document.createdAt
    row.updatedAt = document.updatedAt
    row.deletedAt = nil
    row.syncRevision += 1
  }

  private func applyHost(_ document: SyncDocument, deletedGroups: Set<UUID>) throws -> String? {
    let matching = try context.fetch(FetchDescriptor<StoredHost>()).filter {
      $0.id == document.identity.id
    }
    guard matching.count <= 1 else { throw CloudSyncFailure.localStore }
    if document.deleted {
      guard let row = matching.first else { return nil }
      let reference = row.credentialRef
      row.deletedAt = document.updatedAt
      row.credentialRef = nil
      try setTags([], for: row.id)
      row.syncRevision += 1
      return reference
    }
    guard let value = document.host else { throw CloudSyncFailure.invalidRecord }
    let row =
      matching.first
      ?? StoredHost(
        id: document.identity.id, displayName: value.displayName, hostname: value.hostname,
        port: value.port, username: value.username, authMethod: value.authMethod)
    if matching.isEmpty { context.insert(row) }
    let sameIdentity =
      row.hostname.lowercased() == value.hostname.lowercased()
      && row.port == value.port && row.username == value.username
      && row.authMethod == value.authMethod
    let retired = sameIdentity ? nil : row.credentialRef
    if !sameIdentity { row.credentialRef = nil }
    row.displayName = value.displayName
    row.hostname = value.hostname
    row.port = value.port
    row.username = value.username
    row.authMethodRaw = value.authMethod.rawValue
    row.groupID = value.groupID.flatMap { deletedGroups.contains($0) ? nil : $0 }
    row.notes = value.notes
    row.favorite = value.favorite
    row.sortIndex = value.sortIndex
    row.createdAt = document.createdAt
    row.updatedAt = document.updatedAt
    row.deletedAt = nil
    try setTags(HostTags.normalized(value.tags ?? []), for: row.id)
    try setConnectionOptions(value.connectionOptions ?? HostConnectionOptions(), for: row.id)
    row.syncRevision += 1
    return retired
  }

  func setTags(_ tags: [String], for id: UUID) throws {
    let rows = try context.fetch(FetchDescriptor<StoredHostLabels>()).filter { $0.hostID == id }
    guard rows.count <= 1 else { throw CloudSyncFailure.localStore }
    if let row = rows.first {
      row.labels = tags
    } else if !tags.isEmpty {
      context.insert(StoredHostLabels(hostID: id, labels: tags))
    }
  }
}
