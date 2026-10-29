import Foundation

enum CloudSyncFailure: String, Error, Equatable, Sendable {
  case configuration, signedOut, restricted, accountChanged, zoneRemoved
  case network, quota, invalidRecord, localStore, server, cancelled

  var localizationKey: String { "cloud.error.\(rawValue)" }
}

struct SyncIdentity: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable { case host, group }
  let kind: Kind
  let id: UUID
  static func host(_ id: UUID) -> Self { Self(kind: .host, id: id) }
  static func group(_ id: UUID) -> Self { Self(kind: .group, id: id) }
  var recordName: String { "\(kind == .host ? "h" : "g")-\(id.uuidString.lowercased())" }

  init(kind: Kind, id: UUID) {
    self.kind = kind
    self.id = id
  }
  init?(recordName: String) {
    guard recordName.hasPrefix("h-") || recordName.hasPrefix("g-"),
      let id = UUID(uuidString: String(recordName.dropFirst(2)))
    else { return nil }
    self.init(kind: recordName.hasPrefix("h-") ? .host : .group, id: id)
    guard self.recordName == recordName else { return nil }
  }
}

struct SyncVersion: Codable, Equatable, Sendable {
  let counter: Int64
  let device: UUID
  let mutation: UUID
}

struct SyncedHost: Codable, Equatable, Sendable {
  var displayName: String
  var hostname: String
  var port: Int
  var username: String
  var authMethod: HostAuthMethod
  var groupID: UUID?
  var notes: String
  var favorite: Bool
  var sortIndex: Int
  var tags: [String]? = nil
  var connectionOptions: HostConnectionOptions? = nil

  @MainActor init(_ host: StoredHost) {
    displayName = host.displayName
    hostname = host.hostname
    port = host.port
    username = host.username
    authMethod = host.authMethod
    groupID = host.groupID
    notes = host.notes
    favorite = host.favorite
    sortIndex = host.sortIndex
  }

  func validate() throws {
    guard !hostname.isEmpty, hostname.utf8.count <= 253,
      !hostname.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }),
      !hostname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 256,
      !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      displayName.count <= 256, notes.count <= 4096
    else { throw CloudSyncFailure.invalidRecord }
    if let tags { _ = try HostTags.normalized(tags) }
    try connectionOptions?.validate()
  }
}

struct SyncedGroup: Codable, Equatable, Sendable {
  var name: String
  var sortIndex: Int
}

enum HostTags {
  static func normalized(_ tags: [String]) throws -> [String] {
    guard tags.count <= 32 else { throw HostLibraryError.invalidHost }
    var seen: Set<String> = []
    var result: [String] = []
    for raw in tags {
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.count <= 64,
        !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw HostLibraryError.invalidHost
      }
      if !tag.isEmpty, seen.insert(tag.lowercased()).inserted { result.append(tag) }
    }
    return result
  }
}

/// A closed, noncredential whitelist. Never encode a SwiftData model or a form directly.
struct SyncDocument: Codable, Equatable, Sendable {
  var schemaVersion = 1
  let identity: SyncIdentity
  let version: SyncVersion
  var deleted: Bool
  var createdAt: Date
  var updatedAt: Date
  var host: SyncedHost?
  var group: SyncedGroup?
  static let maximumBytes = 64 * 1024

  func validate() throws {
    guard (1...2).contains(schemaVersion), version.counter > 0, version.counter < Int64.max,
      createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite
    else { throw CloudSyncFailure.invalidRecord }
    if deleted {
      guard host == nil, group == nil else { throw CloudSyncFailure.invalidRecord }
      return
    }
    switch identity.kind {
    case .host:
      guard let host, group == nil else { throw CloudSyncFailure.invalidRecord }
      try host.validate()
      if host.connectionOptions?.isAdvanced == true || !host.authMethod.needsCredential {
        guard schemaVersion == 2 else { throw CloudSyncFailure.invalidRecord }
      }
    case .group:
      guard let group, host == nil,
        !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        group.name.count <= 64
      else { throw CloudSyncFailure.invalidRecord }
    }
  }

  func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumBytes else { throw CloudSyncFailure.invalidRecord }
    return data
  }

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw CloudSyncFailure.invalidRecord }
    do {
      let document = try JSONDecoder().decode(Self.self, from: data)
      try document.validate()
      return document
    } catch { throw CloudSyncFailure.invalidRecord }
  }

  /// Whole-record logical ordering. Tombstones never lose to offline edits.
  func wins(over other: Self) throws -> Bool {
    guard identity == other.identity else { throw CloudSyncFailure.invalidRecord }
    if deleted != other.deleted { return deleted }
    // An offline legacy client cannot represent the route or authentication
    // semantics of v2. Its edits must never silently turn that host into direct SSH.
    if identity.kind == .host, schemaVersion != other.schemaVersion {
      return schemaVersion > other.schemaVersion
    }
    if version.counter != other.version.counter { return version.counter > other.version.counter }
    if version.device != other.version.device {
      return version.device.uuidString > other.version.device.uuidString
    }
    if version.mutation != other.version.mutation {
      return version.mutation.uuidString > other.version.mutation.uuidString
    }
    // Deterministic even for an inconsistent writer reusing a mutation identifier.
    return try other.encoded().lexicographicallyPrecedes(encoded())
  }
}

struct SyncRecordSnapshot: Equatable, Sendable {
  let document: SyncDocument
  var systemFields: Data? = nil
  var pending = false
}

struct SyncSettings: Sendable {
  let enabled: Bool
  let account: String?
  let engineState: Data?
  let lastSync: Date?
}
