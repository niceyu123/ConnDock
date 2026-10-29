import Foundation
import SSHCoreBridge
import SwiftData

struct HostConnectionOptions: Codable, Equatable, Sendable {
  var filesOnly = false
  var jumpHostID: UUID?
  var allowInteractive = false
  var agentFingerprint: String?

  var isAdvanced: Bool { self != Self() }
  func validate() throws {
    if let fingerprint = agentFingerprint {
      let suffix = fingerprint.dropFirst(7)
      guard fingerprint.hasPrefix("SHA256:"), suffix.utf8.count == 43,
        suffix.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43
            || $0 == 47
        })
      else { throw HostLibraryError.invalidHost }
    }
  }
}

@Model final class StoredHostConnectionOptions {
  var hostID: UUID
  var data: Data
  init(hostID: UUID, value: HostConnectionOptions) throws {
    self.hostID = hostID
    data = try JSONEncoder().encode(value)
  }
}

enum HostSchemaV4: VersionedSchema {
  static var versionIdentifier: Schema.Version { .init(4, 0, 0) }
  static var models: [any PersistentModel.Type] {
    HostSchemaV3.models + [StoredHostConnectionOptions.self]
  }
}

extension HostLibrary {
  func storeAgentAuthorization(_ data: Data, for id: UUID) {
    cleanupDefaults.set(data, forKey: "ssh.agent.directory.\(id.uuidString)")
  }
  func agentAccess(for id: UUID, socketPath: String) throws -> AgentSocketAccess {
    guard let bookmark = cleanupDefaults.data(forKey: "ssh.agent.directory.\(id.uuidString)")
    else { throw HostLibraryError.credential }
    return try AgentSocketAccess(bookmark: bookmark, socketPath: socketPath)
  }
  func setAgentSocket(_ path: String, for id: UUID) {
    cleanupDefaults.set(path, forKey: "ssh.agent.socket.\(id.uuidString)")
  }
  func agentSocket(for id: UUID) -> String {
    cleanupDefaults.string(forKey: "ssh.agent.socket.\(id.uuidString)") ?? ""
  }
  func authentication(for host: StoredHost) async throws -> AuthenticationRequest? {
    switch host.authMethod {
    case .password, .ed25519: return try await credential(for: host)?.request
    case .keyboardInteractive: return .keyboardInteractive
    case .agent:
      #if os(macOS)
        let path = agentSocket(for: host.id)
        guard path.hasPrefix("/"),
          let fingerprint = connectionOptions(for: host.id).agentFingerprint
        else { return nil }
        guard (try? agentAccess(for: host.id, socketPath: path)) != nil else { return nil }
        return .agent(socketPath: path, fingerprint: fingerprint)
      #else
        throw HostLibraryError.credential
      #endif
    }
  }
  func connectionOptions(for id: UUID) -> HostConnectionOptions {
    connectionProfiles[id] ?? HostConnectionOptions()
  }

  func storedConnectionOptions(for id: UUID) throws -> HostConnectionOptions {
    let rows = try context.fetch(FetchDescriptor<StoredHostConnectionOptions>()).filter {
      $0.hostID == id
    }
    guard rows.count <= 1 else { throw HostLibraryError.unavailable }
    guard let row = rows.first else { return HostConnectionOptions() }
    let value = try JSONDecoder().decode(HostConnectionOptions.self, from: row.data)
    try value.validate()
    return value
  }

  func setConnectionOptions(_ value: HostConnectionOptions, for id: UUID) throws {
    try value.validate()
    let rows = try context.fetch(FetchDescriptor<StoredHostConnectionOptions>()).filter {
      $0.hostID == id
    }
    guard rows.count <= 1 else { throw HostLibraryError.unavailable }
    if let row = rows.first {
      row.data = try JSONEncoder().encode(value)
    } else if value.isAdvanced {
      context.insert(try StoredHostConnectionOptions(hostID: id, value: value))
    }
  }
}
