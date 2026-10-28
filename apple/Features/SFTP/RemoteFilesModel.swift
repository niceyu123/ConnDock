import Foundation
import Observation
import SSHCoreBridge

enum RemotePaths {
  static func child(_ directory: String, name: String) throws -> String {
    guard !directory.isEmpty, !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\0"), name.utf8.count <= 1024
    else { throw RemoteFailure.Failure(code: .invalidPath) }
    let parent = directory == "/" ? "" : directory.trimmingTrailingSlashes
    let path = "\(parent)/\(name)"
    guard path.utf8.count <= 16_384 else { throw RemoteFailure.Failure(code: .invalidPath) }
    return path
  }

  static func parent(_ path: String) -> String {
    let path = path.trimmingTrailingSlashes
    guard let index = path.lastIndex(of: "/"), index != path.startIndex else { return "/" }
    return String(path[..<index])
  }
}

extension String {
  fileprivate var trimmingTrailingSlashes: String {
    var value = self
    while value.last == "/" { value.removeLast() }
    return value
  }
}

enum TransferDirection { case upload, download }

struct UploadDestination: Equatable {
  let path: String
  let revision: Int
}

enum TransferStatus: String {
  case queued, running, finishing, cancelling, completed, cancelled, failed
  var key: String { "sftp.transfer.\(rawValue)" }
  var isActive: Bool { self == .running || self == .finishing || self == .cancelling }
}

@MainActor @Observable
final class FileTransfer: Identifiable {
  let id = UUID()
  let direction: TransferDirection
  let name: String
  let remotePath: String
  let source: URL?
  let sourceAccess: FileUploadSource?
  var overwrite: Bool
  var status: TransferStatus = .queued
  var bytesTransferred: UInt64 = 0
  var totalBytes: UInt64?
  var errorKey: String?
  var canOverwrite = false
  var downloadedURL: URL?
  @ObservationIgnored var task: Task<Void, Never>?
  @ObservationIgnored var remoteFile: RemoteFile?
  @ObservationIgnored var opening: RemoteOperation?
  @ObservationIgnored var diskFile: TransferDiskFile?

  init(
    direction: TransferDirection, name: String, remotePath: String, source: URL?, overwrite: Bool,
    sourceAccess: FileUploadSource? = nil
  ) {
    self.direction = direction
    self.name = name
    self.remotePath = remotePath
    self.source = source
    self.sourceAccess = sourceAccess
    self.overwrite = overwrite
  }

  var fractionCompleted: Double? {
    guard let totalBytes else { return nil }
    guard totalBytes > 0 else { return status == .completed ? 1 : 0 }
    return min(1, Double(bytesTransferred) / Double(totalBytes))
  }

  func connectionEnded(userInitiated: Bool) {
    guard status.isActive || status == .queued else { return }
    if status == .finishing, direction == .upload {
      status = .failed
      errorKey = "remote.error.commitUnknown"
      opening?.cancel()
      task?.cancel()
      return
    }
    status = userInitiated || status == .cancelling ? .cancelled : .failed
    errorKey = status == .failed ? "remote.error.connectionLost" : nil
    remoteFile?.cancel()
    opening?.cancel()
    task?.cancel()
  }
}

/// Owns only runtime transfer state; paths, file contents and tasks are never put
/// in SwiftData, preferences, logs, or the sync model.
@MainActor @Observable
final class RemoteFilesModel {
  private(set) var entries: [RemoteFileEntry] = []
  private(set) var path: String?
  private(set) var isConnected = false
  private(set) var isLoading = false
  private(set) var transfers: [FileTransfer] = []
  var selectedName: String?
  var errorKey: String?
  var showUploadImporter = false
  @ObservationIgnored private let connection: SshConnection
  @ObservationIgnored private var browser: RemoteFiles?
  @ObservationIgnored private var browsing: Task<Void, Never>?
  @ObservationIgnored private var opening: RemoteOperation?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var locationRevision = 0

  init(connection: SshConnection) { self.connection = connection }

  var selectedEntry: RemoteFileEntry? { entries.first { $0.name == selectedName } }
  var canDownloadSelection: Bool {
    isConnected && (selectedEntry?.kind == .regular || selectedEntry?.kind == .symlink)
  }

  var uploadDestination: UploadDestination? {
    guard isConnected, !isLoading, browser != nil, let path else { return nil }
    return UploadDestination(path: path, revision: locationRevision)
  }

  func isCurrentUploadDestination(_ destination: UploadDestination) -> Bool {
    isConnected && path == destination.path && locationRevision == destination.revision
  }

  func setConnected(_ connected: Bool, userInitiated: Bool = false) {
    isConnected = connected
    if !connected {
      suspendBrowser()
      entries = []
      selectedName = nil
      for transfer in transfers where transfer.status == .queued || transfer.status.isActive {
        transfer.connectionEnded(userInitiated: userInitiated)
      }
    }
  }

  func suspendBrowser() {
    generation += 1
    locationRevision += 1
    opening?.cancel()
    opening = nil
    browsing?.cancel()
    browsing = nil
    browser?.close()
    browser = nil
    isLoading = false
  }

  func browse(_ requestedPath: String? = nil, selecting name: String? = nil) {
    guard isConnected else { return }
    if let requestedPath, requestedPath != path { locationRevision += 1 }
    generation += 1
    let revision = generation
    let destination = requestedPath ?? path ?? "."
    opening?.cancel()
    let operation = RemoteOperation()
    opening = operation
    if browsing != nil {
      browser?.close()
      browser = nil
    }
    browsing?.cancel()
    isLoading = true
    errorKey = nil
    browsing = Task { [weak self] in
      guard let self else { return }
      do {
        let client: RemoteFiles
        if let existing = browser {
          client = existing
        } else {
          client = try await connection.openFilesCancellable(operation: operation)
          guard revision == generation, !Task.isCancelled else {
            client.close()
            return
          }
          browser = client
        }
        let directory = try await client.listDirectory(path: destination)
        guard revision == generation, !Task.isCancelled else { return }
        entries = directory.entries
        path = directory.path
        selectedName = name.flatMap { candidate in
          directory.entries.contains { $0.name == candidate } ? candidate : nil
        }
      } catch {
        guard revision == generation, !Task.isCancelled else { return }
        entries = []
        errorKey = remoteErrorKey(error)
        browser?.close()
        browser = nil
      }
      if revision == generation {
        isLoading = false
        browsing = nil
      }
    }
  }

  func open(_ entry: RemoteFileEntry) {
    selectedName = entry.name
    guard entry.kind == .directory || entry.kind == .symlink else { return }
    do { browse(try RemotePaths.child(path ?? ".", name: entry.name)) } catch {
      errorKey = remoteErrorKey(error)
    }
  }

  func createDirectory(name: String, in directory: String? = nil) async {
    await mutate(in: directory) { client, parent in
      try await client.createDirectory(path: RemotePaths.child(parent, name: name))
    }
  }

  func rename(_ entry: RemoteFileEntry, to name: String, in directory: String? = nil) async {
    await mutate(in: directory) { client, parent in
      try await client.rename(
        source: RemotePaths.child(parent, name: entry.name),
        destination: RemotePaths.child(parent, name: name))
    }
  }

  func remove(_ entry: RemoteFileEntry, in directory: String? = nil) async {
    await mutate(in: directory) { client, parent in
      try await client.remove(path: RemotePaths.child(parent, name: entry.name))
    }
  }

  private func mutate(
    in directory: String?, _ operation: (RemoteFiles, String) async throws -> Void
  ) async {
    if let directory, directory != path || isLoading {
      errorKey = "sftp.error.staleSelection"
      return
    }
    guard isConnected, let browser, let path, !isLoading else { return }
    let revision = generation
    isLoading = true
    errorKey = nil
    do { try await operation(browser, path) } catch {
      if revision == generation { errorKey = remoteErrorKey(error) }
    }
    guard revision == generation else { return }
    isLoading = false
    if errorKey == nil { browse() }
  }

  func upload(_ source: URL, overwrite: Bool = false) {
    enqueue(
      direction: .upload, name: source.lastPathComponent, source: source, overwrite: overwrite)
  }

  @discardableResult
  func upload(
    _ source: FileUploadSource, to destination: UploadDestination, overwrite: Bool = false
  )
    -> Bool
  {
    guard isCurrentUploadDestination(destination) else {
      errorKey = "sftp.error.staleSelection"
      return false
    }
    return enqueue(
      direction: .upload, name: source.url.lastPathComponent, source: source.url,
      overwrite: overwrite, sourceAccess: source, directory: destination.path)
  }

  func download(_ entry: RemoteFileEntry? = nil, from directory: String? = nil) {
    if let directory, directory != path || isLoading {
      errorKey = "sftp.error.staleSelection"
      return
    }
    guard let entry = entry ?? selectedEntry, entry.kind == .regular || entry.kind == .symlink
    else { return }
    enqueue(direction: .download, name: entry.name, source: nil, overwrite: false)
  }

  @discardableResult
  private func enqueue(
    direction: TransferDirection, name: String, source: URL?, overwrite: Bool,
    sourceAccess: FileUploadSource? = nil, directory: String? = nil
  ) -> Bool {
    guard isConnected else {
      errorKey = "remote.error.notConnected"
      return false
    }
    guard transfers.count < 50 else {
      errorKey = "sftp.error.queueFull"
      return false
    }
    do {
      let remotePath = try RemotePaths.child(directory ?? path ?? ".", name: name)
      transfers.append(
        FileTransfer(
          direction: direction, name: name, remotePath: remotePath, source: source,
          overwrite: overwrite, sourceAccess: sourceAccess))
      startQueuedTransfers()
      return true
    } catch {
      errorKey = remoteErrorKey(error)
      return false
    }
  }

  func cancel(_ transfer: FileTransfer) {
    if transfer.status == .queued {
      transfer.status = .cancelled
      return
    }
    guard transfer.status == .running || transfer.status == .cancelling else { return }
    transfer.status = .cancelling
    transfer.remoteFile?.cancel()
    transfer.opening?.cancel()
    transfer.task?.cancel()
  }

  func retry(_ transfer: FileTransfer, overwrite: Bool = false) {
    guard isConnected, transfer.status == .failed || transfer.status == .cancelled else { return }
    transfer.overwrite = transfer.overwrite || overwrite
    transfer.bytesTransferred = 0
    transfer.totalBytes = nil
    transfer.errorKey = nil
    transfer.canOverwrite = false
    transfer.downloadedURL = nil
    transfer.diskFile = nil
    transfer.status = .queued
    startQueuedTransfers()
  }

  func clearFinishedTransfers() {
    transfers.removeAll { !$0.status.isActive && $0.status != .queued }
  }

  private func startQueuedTransfers() {
    guard isConnected else { return }
    var available = 2 - transfers.filter { $0.status.isActive }.count
    for transfer in transfers where transfer.status == .queued && available > 0 {
      available -= 1
      transfer.status = .running
      transfer.task = Task { [weak self, weak transfer] in
        guard let self, let transfer else { return }
        await run(transfer)
        transfer.task = nil
        transfer.remoteFile = nil
        transfer.opening = nil
        startQueuedTransfers()
      }
    }
  }

  private func run(_ transfer: FileTransfer) async {
    let disk = TransferDiskFile()
    let operation = RemoteOperation()
    transfer.opening = operation
    transfer.diskFile = disk
    do {
      try Task.checkCancellation()
      let client = try await connection.openFilesCancellable(operation: operation)
      defer { client.close() }
      try Task.checkCancellation()
      let remote: RemoteFile
      if transfer.direction == .upload, let source = transfer.source {
        let size = try await disk.openUpload(source)
        try Task.checkCancellation()
        transfer.totalBytes = size
        remote = try await client.openWriterCancellable(
          path: transfer.remotePath, size: size, overwrite: transfer.overwrite, operation: operation
        )
      } else {
        _ = try await disk.openDownload(name: transfer.name)
        try Task.checkCancellation()
        remote = try await client.openReaderCancellable(
          path: transfer.remotePath, operation: operation)
        transfer.totalBytes = remote.size()
      }
      client.close()
      transfer.remoteFile = remote
      if Task.isCancelled {
        remote.cancel()
        throw CancellationError()
      }
      var count: UInt64 = 0
      var updated = ContinuousClock.now
      while true {
        try Task.checkCancellation()
        let chunk: Data
        if transfer.direction == .upload {
          chunk = try await disk.readChunk()
          if chunk.isEmpty { break }
          try await remote.writeChunk(bytes: chunk)
        } else {
          chunk = try await remote.readChunk()
          if chunk.isEmpty { break }
          try await disk.writeChunk(chunk)
        }
        count += UInt64(chunk.count)
        let now = ContinuousClock.now
        if updated.duration(to: now) >= .milliseconds(100) {
          transfer.bytesTransferred = count
          updated = now
        }
      }
      try Task.checkCancellation()
      transfer.status = .finishing
      try await remote.finish()
      transfer.bytesTransferred = count
      if transfer.direction == .download {
        transfer.downloadedURL = try await disk.finishDownload()
      } else {
        await disk.close(removeDownload: false)
      }
      transfer.status = .completed
      if transfer.direction == .upload, browser != nil { browse() }
    } catch {
      transfer.remoteFile?.cancel()
      await disk.close(removeDownload: true)
      if transfer.status == .failed,
        transfer.errorKey == "remote.error.connectionLost"
          || transfer.errorKey == "remote.error.commitUnknown"
      {
        return
      }
      if Task.isCancelled || (error as? CancellationError) != nil || remoteCode(error) == .cancelled
      {
        transfer.status = .cancelled
        transfer.errorKey = nil
      } else {
        transfer.status = .failed
        transfer.errorKey = remoteErrorKey(error, localKey: "sftp.error.localFile")
        transfer.canOverwrite = transfer.direction == .upload && remoteCode(error) == .alreadyExists
      }
    }
  }
}

func remoteCode(_ error: Error) -> RemoteFailureCode? {
  if case RemoteFailure.Failure(let code) = error { return code }
  return nil
}

func remoteErrorKey(_ error: Error, localKey: String = "remote.error.remoteFailure") -> String {
  guard let code = remoteCode(error) else { return localKey }
  return switch code {
  case .notConnected: "remote.error.notConnected"
  case .cancelled: "remote.error.cancelled"
  case .timeout: "remote.error.timeout"
  case .permissionDenied: "remote.error.permissionDenied"
  case .notFound: "remote.error.notFound"
  case .alreadyExists: "remote.error.alreadyExists"
  case .unsupported: "remote.error.unsupported"
  case .invalidPath: "remote.error.invalidPath"
  case .directoryTooLarge: "remote.error.directoryTooLarge"
  case .outputLimit: "remote.error.outputLimit"
  case .malformedData: "remote.error.malformedData"
  case .connectionLost: "remote.error.connectionLost"
  case .remoteFailure: "remote.error.remoteFailure"
  case .invalidTransfer: "remote.error.invalidTransfer"
  case .invalidCommand, .invalidServiceName: "ssh.error.invalidConfiguration"
  case .commitUnknown: "remote.error.commitUnknown"
  }
}
