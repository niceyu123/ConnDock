import Foundation

/// Device-only file-provider authorization, never part of a synced host record.
final class AgentSocketAccess {
  static func dedicatedDirectory() throws -> URL {
    let directory = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("ConnDock/Agent", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }
  static func setupCommands(socketPath: String) -> String {
    let quoted = "'" + socketPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "ssh-agent -a \(quoted)\nSSH_AUTH_SOCK=\(quoted) ssh-add"
  }
  let directory: URL
  private let scoped: Bool
  init(directory: URL, socketPath: String) throws {
    let scoped = directory.startAccessingSecurityScopedResource()
    let socket = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == socket.path else {
      if scoped { directory.stopAccessingSecurityScopedResource() }
      throw HostLibraryError.credential
    }
    self.directory = directory
    self.scoped = scoped
  }
  convenience init(bookmark: Data, socketPath: String) throws {
    var stale = false
    #if os(macOS)
      let directory = try URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
    #else
      let directory = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    #endif
    guard !stale else { throw HostLibraryError.credential }
    try self.init(directory: directory, socketPath: socketPath)
  }
  func bookmark() throws -> Data {
    #if os(macOS)
      try directory.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      try directory.bookmarkData()
    #endif
  }
  deinit { if scoped { directory.stopAccessingSecurityScopedResource() } }
}
