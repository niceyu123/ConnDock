import Foundation
import SSHCoreBridge
import XCTest

@testable import ConnDockKit

@MainActor
final class RemoteServicesTests: XCTestCase {
  func testUploadSelectionAcceptsRegularFilesAndRejectsDirectoriesAndWebURLs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("空文件-中文.txt")
    try Data().write(to: file)
    let source = try FileUploadSource(url: file)
    XCTAssertEqual(source.url, file)
    XCTAssertThrowsError(try FileUploadSource(url: directory))
    XCTAssertThrowsError(try FileUploadSource(url: directory.appendingPathComponent("missing")))
    XCTAssertThrowsError(
      try FileUploadSource(url: XCTUnwrap(URL(string: "https://example.invalid/file"))))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

  func testTransferProgressHandlesUnknownZeroAndChangedSizes() {
    let transfer = FileTransfer(
      direction: .download, name: "progress.bin", remotePath: "/progress.bin", source: nil,
      overwrite: false)
    XCTAssertNil(transfer.fractionCompleted)
    transfer.totalBytes = 200
    transfer.bytesTransferred = 50
    XCTAssertEqual(transfer.fractionCompleted, 0.25)
    transfer.bytesTransferred = 250
    XCTAssertEqual(transfer.fractionCompleted, 1)
    transfer.totalBytes = 0
    transfer.bytesTransferred = 0
    transfer.status = .running
    XCTAssertEqual(transfer.fractionCompleted, 0)
    transfer.status = .completed
    XCTAssertEqual(transfer.fractionCompleted, 1)
  }

  func testRemotePathsKeepNamesLiteralAndRejectTraversal() throws {
    XCTAssertEqual(try RemotePaths.child("/tmp", name: "中文 ' ; $(id).txt"), "/tmp/中文 ' ; $(id).txt")
    XCTAssertEqual(try RemotePaths.child("/", name: "file"), "/file")
    XCTAssertEqual(RemotePaths.parent("/home/user/"), "/home")
    XCTAssertEqual(RemotePaths.parent("/home"), "/")
    for name in ["", ".", "..", "a/b", "a\0b"] {
      XCTAssertThrowsError(try RemotePaths.child("/tmp", name: name))
    }
  }

  func testDiskTransferReadsBoundedChunksAndCleansItsOwnDownload() async throws {
    let manager = FileManager.default
    let source = manager.temporaryDirectory.appendingPathComponent(
      "Phase3-\(UUID().uuidString).bin")
    let expected = Data((0..<(TransferDiskFile.chunkBytes * 3 + 17)).map { UInt8($0 % 251) })
    try expected.write(to: source)
    defer { try? manager.removeItem(at: source) }
    let reader = TransferDiskFile()
    let size = try await reader.openUpload(source)
    XCTAssertEqual(size, UInt64(expected.count))
    let writer = TransferDiskFile()
    let destination = try await writer.openDownload(name: "中文🙂.bin")
    var count = 0
    while true {
      let chunk = try await reader.readChunk()
      if chunk.isEmpty { break }
      XCTAssertLessThanOrEqual(chunk.count, 64 * 1024)
      try await writer.writeChunk(chunk)
      count += chunk.count
    }
    let finished = try await writer.finishDownload()
    XCTAssertEqual(finished, destination)
    XCTAssertEqual(count, expected.count)
    XCTAssertEqual(try Data(contentsOf: finished), expected)
    await reader.close(removeDownload: false)
    await writer.close(removeDownload: true)
    XCTAssertFalse(manager.fileExists(atPath: destination.path))
    XCTAssertTrue(
      manager.fileExists(atPath: source.path), "Cleanup must preserve the user's source file")
  }

  func testDiskWriterRejectsOversizedBridgeChunks() async throws {
    let writer = TransferDiskFile()
    _ = try await writer.openDownload(name: "bounded.bin")
    do {
      try await writer.writeChunk(Data(repeating: 0, count: 64 * 1024 + 1))
      XCTFail("Oversized chunks must be rejected")
    } catch {}
    await writer.close(removeDownload: true)
  }

  func testRemoteErrorsExposeOnlyStableLocalizedCodes() {
    XCTAssertEqual(
      remoteErrorKey(RemoteFailure.Failure(code: .permissionDenied)),
      "remote.error.permissionDenied")
    XCTAssertEqual(
      remoteErrorKey(RemoteFailure.Failure(code: .connectionLost)), "remote.error.connectionLost")
    let error = NSError(
      domain: "untrusted", code: 1, userInfo: [NSLocalizedDescriptionKey: "untrusted remote text"])
    XCTAssertEqual(remoteErrorKey(error), "remote.error.remoteFailure")
  }

  func testConnectionLossReportsFailureWhileUserCancellationStaysCancelled() {
    let interrupted = FileTransfer(
      direction: .upload, name: "partial.bin", remotePath: "/partial.bin", source: nil,
      overwrite: false)
    interrupted.status = .running
    interrupted.connectionEnded(userInitiated: false)
    XCTAssertEqual(interrupted.status, .failed)
    XCTAssertEqual(interrupted.errorKey, "remote.error.connectionLost")
    let cancelled = FileTransfer(
      direction: .download, name: "file.bin", remotePath: "/file.bin", source: nil, overwrite: false
    )
    cancelled.connectionEnded(userInitiated: true)
    XCTAssertEqual(cancelled.status, .cancelled)
    XCTAssertNil(cancelled.errorKey)
    let complete = FileTransfer(
      direction: .download, name: "done.bin", remotePath: "/done.bin", source: nil, overwrite: false
    )
    complete.status = .completed
    complete.connectionEnded(userInitiated: false)
    XCTAssertEqual(complete.status, .completed)
    let committing = FileTransfer(
      direction: .upload, name: "commit.bin", remotePath: "/commit.bin", source: nil,
      overwrite: true)
    committing.status = .finishing
    committing.connectionEnded(userInitiated: true)
    XCTAssertEqual(committing.status, .failed)
    XCTAssertEqual(
      committing.errorKey, "remote.error.commitUnknown",
      "Disconnecting during a commit must never claim the remote change was undone")
  }
}
