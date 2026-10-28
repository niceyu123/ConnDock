import Foundation
import Observation

struct RemoteServerIdentity: Codable, Equatable {
  let host: String
  let port: UInt16
  let username: String

  init(_ target: ConnectionTarget) {
    host = target.host.lowercased()
    port = target.port
    username = target.username
  }
}

struct RemoteBookmark: Codable, Identifiable {
  let id: UUID
  let server: RemoteServerIdentity
  let path: String
  let selectedName: String?

  var title: String {
    selectedName ?? path.split(separator: "/").last.map(String.init) ?? "/"
  }
}

/// Explicit path favorites stay on this device and never enter CloudKit.
@MainActor @Observable
final class RemoteBookmarkStore {
  private(set) var bookmarks: [RemoteBookmark] = []
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key = "sftp.bookmarks.v1"
  @ObservationIgnored private var unreadable = false

  init(defaults: UserDefaults) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key) {
      do { bookmarks = try JSONDecoder().decode([RemoteBookmark].self, from: data) } catch {
        unreadable = true
      }
    }
  }

  func items(for target: ConnectionTarget) -> [RemoteBookmark] {
    bookmarks.filter { $0.server == RemoteServerIdentity(target) }
  }

  func contains(_ path: String, selectedName: String? = nil, for target: ConnectionTarget) -> Bool {
    items(for: target).contains { $0.path == path && $0.selectedName == selectedName }
  }

  func toggle(_ path: String, selectedName: String? = nil, for target: ConnectionTarget) throws {
    guard !unreadable, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16_384 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let server = RemoteServerIdentity(target)
    var updated = bookmarks
    if let index = updated.firstIndex(where: {
      $0.server == server && $0.path == path && $0.selectedName == selectedName
    }) {
      updated.remove(at: index)
    } else {
      guard updated.count < 200 else { throw CocoaError(.fileWriteOutOfSpace) }
      updated.append(
        RemoteBookmark(id: UUID(), server: server, path: path, selectedName: selectedName))
    }
    try persist(updated)
  }

  func remove(_ bookmark: RemoteBookmark) throws {
    guard !unreadable else { throw CocoaError(.fileReadCorruptFile) }
    try persist(bookmarks.filter { $0.id != bookmark.id })
  }

  private func persist(_ updated: [RemoteBookmark]) throws {
    let data = try JSONEncoder().encode(updated)
    defaults.set(data, forKey: key)
    bookmarks = updated
  }
}
