import Foundation

/// This payload exists only in memory and inside the authenticated ciphertext.
/// Never write its encoded representation to a file, database, log or sync record.
struct ConfigurationSnapshot: Codable, Sendable {
  struct Host: Codable, Sendable {
    let id: UUID
    var configuration: SyncedHost
    var credential: SavedCredential?
  }
  struct Group: Codable, Sendable {
    let id: UUID
    let configuration: SyncedGroup
  }
  var version = 1
  var groups: [Group]
  var hosts: [Host]

  var credentialCount: Int { hosts.filter { $0.credential != nil }.count }

  func validate() throws {
    guard version == 1 else { throw ConfigurationArchiveError.version }
    guard hosts.count <= 1000, groups.count <= 256 else { throw ConfigurationArchiveError.limit }
    let hostIDs = Set(hosts.map(\.id))
    let groupIDs = Set(groups.map(\.id))
    guard hostIDs.count == hosts.count, groupIDs.count == groups.count else {
      throw ConfigurationArchiveError.invalid
    }
    for group in groups {
      let name = group.configuration.name
      guard !name.isEmpty, name.count <= 64,
        name == name.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw ConfigurationArchiveError.invalid }
    }
    for host in hosts {
      let value = host.configuration
      try value.validate()
      guard value.hostname == value.hostname.trimmingCharacters(in: .whitespacesAndNewlines),
        value.username == value.username.trimmingCharacters(in: .whitespacesAndNewlines),
        value.groupID.map({ groupIDs.contains($0) }) ?? true
      else { throw ConfigurationArchiveError.invalid }
      if let credential = host.credential {
        guard credential.authMethod == value.authMethod else {
          throw ConfigurationArchiveError.invalid
        }
        switch credential {
        case .password(let password):
          guard password.utf8.count <= 64 * 1024 else { throw ConfigurationArchiveError.limit }
        case .ed25519(let key, let passphrase):
          guard key.utf8.count <= 1024 * 1024, (passphrase?.utf8.count ?? 0) <= 64 * 1024 else {
            throw ConfigurationArchiveError.limit
          }
        }
      }
      if let jumpID = value.connectionOptions?.jumpHostID {
        guard jumpID != host.id, let jump = hosts.first(where: { $0.id == jumpID }),
          jump.configuration.connectionOptions?.jumpHostID == nil
        else { throw ConfigurationArchiveError.route }
      }
    }
  }

  func encoded() throws -> Data {
    try validate()
    let result = try JSONEncoder().encode(self)
    guard result.count <= ConfigurationArchiveCryptor.maximumPlaintextBytes else {
      throw ConfigurationArchiveError.limit
    }
    return result
  }

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= ConfigurationArchiveCryptor.maximumPlaintextBytes else {
      throw ConfigurationArchiveError.limit
    }
    do {
      let result = try JSONDecoder().decode(Self.self, from: data)
      try result.validate()
      return result
    } catch let error as ConfigurationArchiveError { throw error } catch {
      throw ConfigurationArchiveError.invalid
    }
  }

  @MainActor
  static func capture(from library: HostLibrary) async throws -> Self {
    guard library.hosts.count <= 1000, library.groups.count <= 256 else {
      throw ConfigurationArchiveError.limit
    }
    try library.beginRemoteMerge()
    defer { library.endRemoteMerge() }
    var hosts: [Host] = []
    for row in library.hosts {
      try Task.checkCancellation()
      var configuration = SyncedHost(row)
      configuration.tags = library.tags(for: row.id)
      configuration.connectionOptions = library.connectionOptions(for: row.id)
      let credential = try await library.credential(for: row)
      try Task.checkCancellation()
      guard row.credentialRef == nil || credential != nil else { throw HostLibraryError.credential }
      hosts.append(Host(id: row.id, configuration: configuration, credential: credential))
    }
    let result = Self(
      groups: library.groups.map {
        Group(id: $0.id, configuration: SyncedGroup(name: $0.name, sortIndex: $0.sortIndex))
      }, hosts: hosts)
    try result.validate()
    return result
  }
}

struct ConfigurationImportReport {
  var importedHosts = 0
  var importedGroups = 0
  var importedCredentials = 0
  var skippedHosts = 0
}
