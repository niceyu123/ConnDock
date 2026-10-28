import Foundation
import SwiftData

enum HostSchemaV2: VersionedSchema {
  static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
  static var models: [any PersistentModel.Type] {
    [StoredHost.self, StoredHostGroup.self, StoredSyncRecord.self, StoredSyncState.self]
  }
}

enum HostMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [HostSchemaV1.self, HostSchemaV2.self, HostSchemaV3.self]
  }
  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: HostSchemaV1.self, toVersion: HostSchemaV2.self),
      .lightweight(fromVersion: HostSchemaV2.self, toVersion: HostSchemaV3.self),
    ]
  }
}

enum HostSchemaV3: VersionedSchema {
  static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
  static var models: [any PersistentModel.Type] {
    [
      StoredHost.self, StoredHostGroup.self, StoredSyncRecord.self, StoredSyncState.self,
      StoredHostLabels.self,
    ]
  }
}

@Model final class StoredHostLabels {
  var hostID: UUID
  var labels: [String]
  init(hostID: UUID, labels: [String]) {
    self.hostID = hostID
    self.labels = labels
  }
}

@Model final class StoredSyncRecord {
  var recordName: String
  var documentData: Data
  var systemFields: Data?
  var pending: Bool
  init(document: SyncDocument) throws {
    recordName = document.identity.recordName
    documentData = try document.encoded()
    pending = true
  }
}

@Model final class StoredSyncState {
  var key: String
  var deviceID: UUID
  var clock: Int64
  var enabled: Bool
  var account: String?
  var engineState: Data?
  var lastSync: Date?
  init() {
    key = "private-v1"
    deviceID = UUID()
    clock = 0
    enabled = false
  }
}
