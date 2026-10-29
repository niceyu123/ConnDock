import Foundation
import Observation
import SwiftData

enum HostLibraryError: Error {
  case invalidHost, invalidGroup, duplicateGroup, conflict, notFound, busy, unavailable, credential,
    jumpCredential
  var localizationKey: String {
    switch self {
    case .invalidHost: "storage.error.invalidHost"
    case .invalidGroup: "storage.error.invalidGroup"
    case .duplicateGroup: "storage.error.duplicateGroup"
    case .conflict: "storage.error.conflict"
    case .notFound: "storage.error.notFound"
    case .busy: "storage.error.busy"
    case .unavailable: "storage.error.unavailable"
    case .credential: "storage.error.credential"
    case .jumpCredential: "ssh.error.jumpCredential"
    }
  }
}

@MainActor @Observable
final class HostLibrary {
  private(set) var hosts: [StoredHost] = []
  private(set) var groups: [StoredHostGroup] = []
  private(set) var hostTags: [UUID: [String]] = [:]
  private(set) var connectionProfiles: [UUID: HostConnectionOptions] = [:]
  private(set) var isBusy = false
  private(set) var cleanupPending = false
  private(set) var refreshErrorKey: String?
  @ObservationIgnored var onSyncChange: (() -> Void)?
  @ObservationIgnored private let container: ModelContainer
  @ObservationIgnored let context: ModelContext
  @ObservationIgnored private let vault: any CredentialStorage
  @ObservationIgnored let cleanupDefaults: UserDefaults
  @ObservationIgnored private let cleanupKey = "credentials.pendingDeletion.v1"

  init(
    storeURL: URL? = nil, memoryOnly: Bool = false,
    vault: any CredentialStorage = KeychainCredentialStorage(),
    cleanupDefaults: UserDefaults = .standard
  ) throws {
    self.vault = vault
    self.cleanupDefaults = cleanupDefaults
    let schema = Schema(versionedSchema: HostSchemaV4.self)
    let configuration: ModelConfiguration
    if memoryOnly {
      configuration = ModelConfiguration(
        schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    } else {
      let url: URL
      if let storeURL {
        url = storeURL
      } else {
        let directory = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true
        ).appendingPathComponent("SSHClient", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Hosts-v1.store")
      }
      configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    }
    container = try ModelContainer(
      for: schema, migrationPlan: HostMigrationPlan.self, configurations: [configuration])
    context = ModelContext(container)
    context.autosaveEnabled = false
    try prepareSyncStorage()
    try reload()
    cleanupPending = !(cleanupDefaults.stringArray(forKey: cleanupKey) ?? []).isEmpty
  }

  private func reload() throws {
    var profiles: [UUID: HostConnectionOptions] = [:]
    for row in try context.fetch(FetchDescriptor<StoredHostConnectionOptions>()) {
      let value = try JSONDecoder().decode(HostConnectionOptions.self, from: row.data)
      try value.validate()
      guard profiles.updateValue(value, forKey: row.hostID) == nil else {
        throw HostLibraryError.unavailable
      }
    }
    connectionProfiles = profiles
    hostTags = [:]
    for row in try context.fetch(FetchDescriptor<StoredHostLabels>()) {
      guard hostTags.updateValue(row.labels, forKey: row.hostID) == nil else {
        throw HostLibraryError.unavailable
      }
    }
    hosts = try context.fetch(FetchDescriptor<StoredHost>()).filter { $0.deletedAt == nil }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    groups = try context.fetch(FetchDescriptor<StoredHostGroup>()).filter { $0.deletedAt == nil }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func commit(syncChanges: [SyncIdentity] = []) throws {
    do {
      try stageSyncChanges(syncChanges)
      try context.save()
    } catch {
      context.rollback()
      try? reload()
      throw HostLibraryError.unavailable
    }
    // A successful commit must not be treated as rolled back if only the
    // following UI refresh fails; its Keychain reference is already durable.
    do {
      try reload()
      refreshErrorKey = nil
    } catch { refreshErrorKey = "storage.error.unavailable" }
    if !syncChanges.isEmpty { onSyncChange?() }
  }

  func refresh() throws {
    try reload()
    refreshErrorKey = nil
  }

  func beginRemoteMerge() throws {
    guard !isBusy else { throw HostLibraryError.busy }
    isBusy = true
  }
  func endRemoteMerge() { isBusy = false }

  func host(_ id: UUID) -> StoredHost? { hosts.first { $0.id == id } }
  func tags(for id: UUID) -> [String] { hostTags[id] ?? [] }

  func matching(search: String = "", favoritesOnly: Bool = false, recentOnly: Bool = false)
    -> [StoredHost]
  {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = hosts.filter { host in
      (!favoritesOnly || host.favorite) && (!recentOnly || host.lastConnectedAt != nil)
        && (query.isEmpty
          || ([host.title, host.hostname, host.username, host.notes] + tags(for: host.id)).contains
          {
            $0.localizedStandardContains(query)
          })
    }
    return recentOnly
      ? result.sorted {
        ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
      } : result
  }

  private func validate(_ draft: HostDraft) throws {
    guard !draft.hostname.isEmpty, draft.hostname.utf8.count <= 253,
      !draft.hostname.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" || $0 == "@" }
      ),
      !draft.hostname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      draft.port > 0, !draft.username.isEmpty, draft.username.utf8.count <= 256,
      !draft.username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      draft.displayName.count <= 256, draft.notes.count <= 4096
    else { throw HostLibraryError.invalidHost }
    if let groupID = draft.groupID, !groups.contains(where: { $0.id == groupID }) {
      throw HostLibraryError.invalidGroup
    }
  }

  func saveHost(
    _ input: HostDraft, credential: SavedCredential? = nil,
    rememberCredential: Bool = false
  ) async throws -> StoredHost {
    guard !isBusy else { throw HostLibraryError.busy }
    isBusy = true
    defer { isBusy = false }
    var draft = input
    draft.hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    try validate(draft)
    if let options = draft.connectionOptions {
      try options.validate()
      if let jumpID = options.jumpHostID {
        guard jumpID != draft.id, let jump = host(jumpID),
          connectionOptions(for: jump.id).jumpHostID == nil
        else {
          throw HostLibraryError.invalidHost
        }
      }
    }
    let tags = try draft.tags.map { try HostTags.normalized($0) }
    let existing = draft.id.flatMap(host)
    if draft.id != nil && existing == nil { throw HostLibraryError.notFound }
    if let existing, draft.revision != existing.syncRevision { throw HostLibraryError.conflict }
    if let credential, credential.authMethod != draft.authMethod {
      throw HostLibraryError.credential
    }
    let oldReference = existing?.credentialRef
    let identityUnchanged =
      existing.map {
        $0.hostname.lowercased() == draft.hostname.lowercased()
          && $0.port == Int(draft.port) && $0.username == draft.username
          && $0.authMethod == draft.authMethod
      } ?? false
    var newReference = rememberCredential && identityUnchanged ? oldReference : nil
    var createdReference: String?
    if rememberCredential, let credential {
      let reference = UUID().uuidString
      do { try await vault.store(credential, reference: reference) } catch {
        throw HostLibraryError.credential
      }
      newReference = reference
      createdReference = reference
    }
    let row =
      existing
      ?? StoredHost(
        displayName: draft.displayName, hostname: draft.hostname,
        port: Int(draft.port), username: draft.username, authMethod: draft.authMethod)
    if existing == nil { context.insert(row) }
    row.displayName = draft.displayName
    row.hostname = draft.hostname
    row.port = Int(draft.port)
    row.username = draft.username
    row.authMethodRaw = draft.authMethod.rawValue
    row.groupID = draft.groupID
    row.notes = draft.notes
    row.favorite = draft.favorite
    row.credentialRef = newReference
    row.updatedAt = Date()
    if existing != nil { row.syncRevision += 1 }
    do {
      if let options = draft.connectionOptions { try setConnectionOptions(options, for: row.id) }
      if let tags { try setTags(tags, for: row.id) }
      try commit(syncChanges: [.host(row.id)])
    } catch {
      context.rollback()
      if let createdReference { await retire(createdReference) }
      throw error
    }
    if let oldReference, oldReference != newReference { await retire(oldReference) }
    return row
  }

  func credential(for host: StoredHost, allowsUserInteraction: Bool = true) async throws
    -> SavedCredential?
  {
    guard let reference = host.credentialRef else { return nil }
    let identity = host.target
    do {
      let value: SavedCredential?
      if allowsUserInteraction {
        value = try await vault.load(reference: reference)
      } else {
        value = try await vault.loadForAutomation(reference: reference)
      }
      guard host.deletedAt == nil, host.credentialRef == reference,
        host.target.hasSameIdentity(as: identity)
      else {
        throw HostLibraryError.conflict
      }
      guard value == nil || value?.authMethod == host.authMethod else {
        throw HostLibraryError.credential
      }
      return value
    } catch let error as HostLibraryError { throw error } catch {
      throw HostLibraryError.credential
    }
  }

  func deleteHost(_ id: UUID) async throws {
    guard !isBusy else { throw HostLibraryError.busy }
    guard let row = host(id) else { throw HostLibraryError.notFound }
    isBusy = true
    defer { isBusy = false }
    let reference = row.credentialRef
    row.deletedAt = Date()
    row.updatedAt = Date()
    row.syncRevision += 1
    row.credentialRef = nil
    do {
      try setTags([], for: row.id)
      try commit(syncChanges: [.host(row.id)])
    } catch {
      context.rollback()
      throw error
    }
    if let reference { await retire(reference) }
  }

  func toggleFavorite(_ id: UUID) throws {
    guard !isBusy else { throw HostLibraryError.busy }
    guard let row = host(id) else { throw HostLibraryError.notFound }
    row.favorite.toggle()
    row.updatedAt = Date()
    row.syncRevision += 1
    try commit(syncChanges: [.host(row.id)])
  }

  func markConnected(_ id: UUID) throws {
    guard let row = host(id) else { return }
    row.lastConnectedAt = Date()
    try commit()
  }

  private func groupName(_ name: String, excluding id: UUID? = nil) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 64 else { throw HostLibraryError.invalidGroup }
    guard
      !groups.contains(where: {
        $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else { throw HostLibraryError.duplicateGroup }
    return name
  }

  @discardableResult
  func createGroup(name: String) throws -> StoredHostGroup {
    guard !isBusy else { throw HostLibraryError.busy }
    let row = StoredHostGroup(name: try groupName(name))
    context.insert(row)
    try commit(syncChanges: [.group(row.id)])
    return row
  }

  func renameGroup(_ id: UUID, name: String, expectedRevision: Int64) throws {
    guard !isBusy else { throw HostLibraryError.busy }
    guard let row = groups.first(where: { $0.id == id }) else { throw HostLibraryError.notFound }
    guard row.syncRevision == expectedRevision else { throw HostLibraryError.conflict }
    row.name = try groupName(name, excluding: id)
    row.updatedAt = Date()
    row.syncRevision += 1
    try commit(syncChanges: [.group(row.id)])
  }

  func deleteGroup(_ id: UUID) throws {
    guard !isBusy else { throw HostLibraryError.busy }
    guard let row = groups.first(where: { $0.id == id }) else { throw HostLibraryError.notFound }
    let members = hosts.filter { $0.groupID == id }
    for host in members {
      host.groupID = nil
      host.updatedAt = Date()
      host.syncRevision += 1
    }
    row.deletedAt = Date()
    row.updatedAt = Date()
    row.syncRevision += 1
    try commit(syncChanges: members.map { .host($0.id) } + [.group(row.id)])
  }

  func retire(_ reference: String) async {
    var pending = Set(cleanupDefaults.stringArray(forKey: cleanupKey) ?? [])
    pending.insert(reference)
    cleanupDefaults.set(Array(pending), forKey: cleanupKey)
    do {
      try await vault.delete(reference: reference)
      pending.remove(reference)
      cleanupDefaults.set(Array(pending), forKey: cleanupKey)
    } catch {}
    cleanupPending = !pending.isEmpty
  }

  func retryCredentialCleanup() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let pending = cleanupDefaults.stringArray(forKey: cleanupKey) ?? []
    let referenced = Set(hosts.compactMap(\.credentialRef))
    for reference in pending where !referenced.contains(reference) { await retire(reference) }
  }
}
