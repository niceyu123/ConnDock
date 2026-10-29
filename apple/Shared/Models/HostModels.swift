import Foundation
import SwiftData

enum HostAuthMethod: String, CaseIterable, Codable, Sendable {
  case password, ed25519, keyboardInteractive, agent
  var titleKey: String {
    switch self {
    case .password: return "host.password"
    case .ed25519: return "host.key"
    case .keyboardInteractive: return "host.keyboardInteractive"
    case .agent: return "host.agent"
    }
  }
  var needsCredential: Bool { self == .password || self == .ed25519 }
}

enum HostSchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredHost.self, StoredHostGroup.self] }
}

@Model
final class StoredHost {
  var id: UUID
  var displayName: String
  var hostname: String
  var port: Int
  var username: String
  var authMethodRaw: String
  var credentialRef: String?
  var groupID: UUID?
  var notes: String
  var favorite: Bool
  var sortIndex: Int
  var createdAt: Date
  var updatedAt: Date
  var deletedAt: Date?
  var syncRevision: Int64
  var lastConnectedAt: Date?

  init(
    id: UUID = UUID(), displayName: String, hostname: String, port: Int, username: String,
    authMethod: HostAuthMethod, groupID: UUID? = nil, notes: String = "", favorite: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.hostname = hostname
    self.port = port
    self.username = username
    authMethodRaw = authMethod.rawValue
    self.groupID = groupID
    self.notes = notes
    self.favorite = favorite
    sortIndex = 0
    let now = Date()
    createdAt = now
    updatedAt = now
    syncRevision = 1
  }

  var authMethod: HostAuthMethod { HostAuthMethod(rawValue: authMethodRaw) ?? .password }
  var title: String { displayName.isEmpty ? hostname : displayName }
  var target: ConnectionTarget {
    ConnectionTarget(
      displayName: displayName, host: hostname, port: UInt16(exactly: port) ?? 0,
      username: username, usesPrivateKey: authMethod == .ed25519, authenticationMethod: authMethod)
  }
}

@Model
final class StoredHostGroup {
  var id: UUID
  var name: String
  var sortIndex: Int
  var createdAt: Date
  var updatedAt: Date
  var deletedAt: Date?
  var syncRevision: Int64

  init(name: String) {
    id = UUID()
    self.name = name
    sortIndex = 0
    let now = Date()
    createdAt = now
    updatedAt = now
    syncRevision = 1
  }
}

/// Nonsecret form data. Authentication material has a separate Keychain type.
struct HostDraft {
  var id: UUID? = nil
  var revision: Int64? = nil
  var displayName: String
  var hostname: String
  var port: UInt16 = 22
  var username: String
  var authMethod: HostAuthMethod = .password
  var groupID: UUID? = nil
  var notes: String = ""
  var favorite: Bool = false
  var tags: [String]? = nil
  var connectionOptions: HostConnectionOptions? = nil

  init(
    displayName: String, hostname: String, port: UInt16 = 22, username: String,
    authMethod: HostAuthMethod = .password
  ) {
    self.displayName = displayName
    self.hostname = hostname
    self.port = port
    self.username = username
    self.authMethod = authMethod
  }

  init(host: StoredHost) {
    id = host.id
    revision = host.syncRevision
    displayName = host.displayName
    hostname = host.hostname
    port = UInt16(exactly: host.port) ?? 0
    username = host.username
    authMethod = host.authMethod
    groupID = host.groupID
    notes = host.notes
    favorite = host.favorite
  }

  var target: ConnectionTarget {
    ConnectionTarget(
      displayName: displayName, host: hostname, port: port,
      username: username, usesPrivateKey: authMethod == .ed25519, authenticationMethod: authMethod)
  }
}
