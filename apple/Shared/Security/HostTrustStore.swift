import Foundation

struct HostTrustRecord: Codable, Equatable {
  let host: String
  let port: UInt16
  let algorithm: String
  let fingerprint: String
  let trustedAt: Date
}

/// Local trust decisions are deliberately separate from future synced hosts.
@MainActor
final class HostTrustStore {
  private let defaults: UserDefaults
  private let key = "ssh.hostTrust.v1"
  private var records: [HostTrustRecord] = []
  private(set) var isCorrupt = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key) {
      do { records = try JSONDecoder().decode([HostTrustRecord].self, from: data) } catch {
        isCorrupt = true
      }
    }
  }

  func fingerprint(host: String, port: UInt16) throws -> String? {
    guard !isCorrupt else { throw TrustError.corrupt }
    return records.first { $0.host == host.lowercased() && $0.port == port }?.fingerprint
  }

  func remember(host: String, port: UInt16, algorithm: String, fingerprint: String) throws {
    guard !isCorrupt else { throw TrustError.corrupt }
    if let existing = try self.fingerprint(host: host, port: port), existing != fingerprint {
      throw TrustError.changed
    }
    records.removeAll { $0.host == host.lowercased() && $0.port == port }
    records.append(
      HostTrustRecord(
        host: host.lowercased(), port: port, algorithm: algorithm,
        fingerprint: fingerprint, trustedAt: Date()))
    defaults.set(try JSONEncoder().encode(records), forKey: key)
  }

  enum TrustError: Error { case corrupt, changed }
}
