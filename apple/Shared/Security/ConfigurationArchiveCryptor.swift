import CommonCrypto
import CryptoKit
import Foundation
import Security

enum ConfigurationArchiveError: String, Error {
  case invalid, version, limit, password, unlock, read, write, route
  var localizationKey: String { "backup.error.\(rawValue)" }
}

enum ConfigurationArchiveCryptor {
  static let maximumPlaintextBytes = 16 * 1024 * 1024
  static let maximumFileBytes = 24 * 1024 * 1024
  private static let format = "ConnDock.ConfigurationBackup"
  private static let rounds = 600_000
  private static let authenticatedHeader = Data(
    "ConnDock.ConfigurationBackup|1|PBKDF2-HMAC-SHA256|600000|AES-256-GCM".utf8)

  private struct Envelope: Codable {
    let format: String
    let version: Int
    let kdf: String
    let rounds: Int
    let salt: Data
    let sealed: Data
  }

  static func seal(_ plaintext: Data, password: String) throws -> Data {
    guard password.count >= 12, password.utf8.count <= 1024 else {
      throw ConfigurationArchiveError.password
    }
    guard plaintext.count <= maximumPlaintextBytes else { throw ConfigurationArchiveError.limit }
    var salt = Data(count: 16)
    let status = salt.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw ConfigurationArchiveError.write }
    let key = try deriveKey(password: password, salt: salt)
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedHeader)
    guard let sealed = box.combined else { throw ConfigurationArchiveError.write }
    let envelope = Envelope(
      format: format, version: 1, kdf: "PBKDF2-HMAC-SHA256", rounds: rounds,
      salt: salt, sealed: sealed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let result = try encoder.encode(envelope)
    guard result.count <= maximumFileBytes else { throw ConfigurationArchiveError.limit }
    return result
  }

  static func open(_ archive: Data, password: String) throws -> Data {
    guard archive.count <= maximumFileBytes else { throw ConfigurationArchiveError.limit }
    guard !password.isEmpty, password.utf8.count <= 1024 else {
      throw ConfigurationArchiveError.password
    }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: archive),
      envelope.format == format
    else { throw ConfigurationArchiveError.invalid }
    guard envelope.version == 1 else { throw ConfigurationArchiveError.version }
    // Fixed, bounded work. An untrusted file cannot select an excessive KDF cost.
    guard envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.rounds == rounds,
      envelope.salt.count == 16, envelope.sealed.count >= 28,
      envelope.sealed.count <= maximumPlaintextBytes + 28
    else { throw ConfigurationArchiveError.invalid }
    do {
      let key = try deriveKey(password: password, salt: envelope.salt)
      return try AES.GCM.open(
        AES.GCM.SealedBox(combined: envelope.sealed), using: key,
        authenticating: authenticatedHeader)
    } catch { throw ConfigurationArchiveError.unlock }
  }

  private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
    var bytes = Data(count: 32)
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    let status = password.withCString { passwordBytes in
      salt.withUnsafeBytes { saltBytes in
        bytes.withUnsafeMutableBytes { keyBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
            keyBytes.bindMemory(to: UInt8.self).baseAddress, keyBytes.count)
        }
      }
    }
    guard status == kCCSuccess else { throw ConfigurationArchiveError.write }
    return SymmetricKey(data: bytes)
  }
}
