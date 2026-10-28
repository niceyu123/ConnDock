import Foundation
import Observation
import Security

struct SavedCommand: Codable, Identifiable, Sendable {
  var id = UUID()
  var name: String
  var command: String

  var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 256
      && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && command.utf8.count <= 8192
      && command.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
      }
  }
}

/// Only commands explicitly saved by the user are retained. They are protected
/// by the local Keychain, without command history, logging, or cloud replication.
@MainActor @Observable
final class CommandLibrary {
  private(set) var commands: [SavedCommand] = []
  private(set) var isLoaded = false
  private(set) var isBusy = false
  private(set) var errorKey: String?
  @ObservationIgnored private let storage = CommandSnippetStorage()

  func load() async {
    guard !isLoaded, !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      commands = try await storage.load()
      isLoaded = true
      errorKey = nil
    } catch { errorKey = "commands.error.storage" }
  }

  func save(_ command: SavedCommand) async -> Bool {
    guard isLoaded, !isBusy else { return false }
    guard command.isValid else {
      errorKey = "commands.error.invalid"
      return false
    }
    var updated = commands
    var cleaned = command
    cleaned.name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = updated.firstIndex(where: { $0.id == command.id }) {
      updated[index] = cleaned
    } else {
      guard updated.count < 100 else {
        errorKey = "commands.error.limit"
        return false
      }
      updated.append(cleaned)
    }
    return await persist(updated)
  }

  func remove(_ command: SavedCommand) async {
    guard isLoaded, !isBusy else { return }
    _ = await persist(commands.filter { $0.id != command.id })
  }

  private func persist(_ updated: [SavedCommand]) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await storage.save(updated)
      commands = updated
      errorKey = nil
      return true
    } catch {
      errorKey = "commands.error.storage"
      return false
    }
  }
}

private actor CommandSnippetStorage {
  private let service: String

  init() {
    let identity =
      ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] == "1"
      ? "UITesting" : Bundle.main.bundleIdentifier ?? "ConnDock"
    service = "SSHClient.SavedCommands.v1.\(identity)"
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "saved-commands",
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load() throws -> [SavedCommand] {
    var attributes = query
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &value)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = value as? Data, data.count <= 1_048_576 else {
      throw CredentialStorageError.unavailable
    }
    let commands = try JSONDecoder().decode([SavedCommand].self, from: data)
    guard commands.count <= 100, commands.allSatisfy(\.isValid),
      Set(commands.map(\.id)).count == commands.count
    else { throw CredentialStorageError.corrupt }
    return commands
  }

  func save(_ commands: [SavedCommand]) throws {
    let data = try JSONEncoder().encode(commands)
    guard data.count <= 1_048_576 else { throw CredentialStorageError.unavailable }
    let updates = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw CredentialStorageError.status(status) }
    var attributes = query
    attributes[kSecValueData as String] = data
    #if os(iOS)
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    #endif
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw CredentialStorageError.status(added) }
  }
}
