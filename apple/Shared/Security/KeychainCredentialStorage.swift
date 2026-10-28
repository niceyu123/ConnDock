import Foundation
import SSHCoreBridge
import Security

// Never add diagnostic conformance or include these values in UI errors/logs.
enum SavedCredential: Codable, Equatable, Sendable {
  case password(String)
  case ed25519(privateKey: String, passphrase: String?)

  var request: AuthenticationRequest {
    switch self {
    case .password(let value): .password(password: value)
    case .ed25519(let key, let passphrase): .ed25519(privateKey: key, passphrase: passphrase)
    }
  }
  var authMethod: HostAuthMethod {
    switch self {
    case .password: .password
    case .ed25519: .ed25519
    }
  }
}

enum CredentialStorageError: Error {
  case unavailable
  case status(OSStatus)
  case corrupt
}

protocol CredentialStorage: Sendable {
  func store(_ value: SavedCredential, reference: String) async throws
  func load(reference: String) async throws -> SavedCredential?
  func loadForAutomation(reference: String) async throws -> SavedCredential?
  func delete(reference: String) async throws
}

extension CredentialStorage {
  // An unknown implementation must not fall back to a potentially interactive load.
  func loadForAutomation(reference: String) async throws -> SavedCredential? {
    throw CredentialStorageError.unavailable
  }
}

/// All SecItem work runs off MainActor. macOS uses the system login Keychain;
/// iOS uses its data-protected app Keychain. Neither path enables synchronization.
actor KeychainCredentialStorage: CredentialStorage {
  private let service: String
  init(service: String = "SSHClient.LocalCredentials.v1") { self.service = service }

  private struct Envelope: Codable {
    let version: Int
    let value: SavedCredential
  }

  private func query(_ reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func store(_ value: SavedCredential, reference: String) throws {
    var attributes = query(reference)
    attributes[kSecValueData as String] = try JSONEncoder().encode(
      Envelope(version: 1, value: value))
    #if os(iOS)
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    #endif
    let result = SecItemAdd(attributes as CFDictionary, nil)
    guard result == errSecSuccess else { throw CredentialStorageError.status(result) }
  }

  func load(reference: String) throws -> SavedCredential? {
    try read(reference: reference, allowInteraction: true)
  }

  func loadForAutomation(reference: String) async throws -> SavedCredential? {
    try read(reference: reference, allowInteraction: false)
  }

  private func read(reference: String, allowInteraction: Bool) throws -> SavedCredential? {
    var attributes = query(reference)
    if !allowInteraction {
      attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CredentialStorageError.status(status) }
    guard let data = result as? Data,
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1
    else {
      throw CredentialStorageError.corrupt
    }
    return envelope.value
  }

  func delete(reference: String) throws {
    let status = SecItemDelete(query(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStorageError.status(status)
    }
  }
}
