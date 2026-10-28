import Foundation

/// Keeps the user's file grant alive while a selection waits for confirmation,
/// a queue slot, or a retry. Reading still happens in bounded chunks off the UI actor.
final class FileUploadSource: Sendable {
  let url: URL
  private let scoped: Bool

  init(url: URL) throws {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    let scoped = url.startAccessingSecurityScopedResource()
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
    } catch {
      if scoped { url.stopAccessingSecurityScopedResource() }
      throw error
    }
    self.url = url
    self.scoped = scoped
  }

  deinit {
    if scoped { url.stopAccessingSecurityScopedResource() }
  }
}

/// File I/O runs outside the main actor. Only one 64 KiB block crosses this actor
/// and UniFFI at a time; Rust never receives a local path or sandbox bookmark.
actor TransferDiskFile {
  static let chunkBytes = 64 * 1024
  private var handle: FileHandle?
  private var scopedSource: URL?
  private var downloadDirectory: URL?
  private var downloadURL: URL?

  deinit {
    try? handle?.close()
    scopedSource?.stopAccessingSecurityScopedResource()
    if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
  }

  func openUpload(_ url: URL) throws -> UInt64 {
    if url.startAccessingSecurityScopedResource() { scopedSource = url }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    handle = try FileHandle(forReadingFrom: url)
    return UInt64(size)
  }

  func openDownload(name: String) throws -> URL {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let manager = FileManager.default
    let caches = try manager.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = caches.appendingPathComponent(
      "ConnDockTransfers/\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    downloadDirectory = directory
    let url = directory.appendingPathComponent(name)
    guard
      manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    downloadURL = url
    handle = try FileHandle(forWritingTo: url)
    return url
  }

  func readChunk() throws -> Data {
    guard let handle else { throw CocoaError(.fileReadUnknown) }
    return try handle.read(upToCount: Self.chunkBytes) ?? Data()
  }

  func writeChunk(_ data: Data) throws {
    guard let handle, data.count <= Self.chunkBytes else { throw CocoaError(.fileWriteUnknown) }
    try handle.write(contentsOf: data)
  }

  func finishDownload() throws -> URL {
    guard let handle, let downloadURL else { throw CocoaError(.fileWriteUnknown) }
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    return downloadURL
  }

  func close(removeDownload: Bool) {
    try? handle?.close()
    handle = nil
    scopedSource?.stopAccessingSecurityScopedResource()
    scopedSource = nil
    if removeDownload, let downloadDirectory {
      try? FileManager.default.removeItem(at: downloadDirectory)
      self.downloadDirectory = nil
      downloadURL = nil
    }
  }
}
