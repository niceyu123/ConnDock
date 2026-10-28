#if os(macOS)
  import Darwin
  import Foundation
  import Security

  enum MCPPeerVerifier {
    static func verify(_ fd: Int32, expectedExecutable: URL) throws -> MCPSource {
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
        throw MCPFailure("PEER_NOT_TRUSTED")
      }
      var token = audit_token_t()
      var size = socklen_t(MemoryLayout<audit_token_t>.size)
      guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
        size == MemoryLayout<audit_token_t>.size
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      let tokenData = withUnsafeBytes(of: token) { Data($0) }
      var dynamic: SecCode?
      let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
      guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamic) == errSecSuccess,
        let dynamic
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      // The helper requirement comes from the sealed running App, never from
      // an unchecked executable that another same-user process replaced.
      var own: SecCode?
      var ownRequirement: SecRequirement?
      var ownStatic: SecStaticCode?
      var sealedApp: SecStaticCode?
      let strictNested = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
      guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
        SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
        SecCodeCopyDesignatedRequirement(ownStatic, [], &ownRequirement) == errSecSuccess,
        let ownRequirement,
        SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &sealedApp)
          == errSecSuccess,
        let sealedApp,
        SecStaticCodeCheckValidity(sealedApp, strictNested, ownRequirement) == errSecSuccess
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      var expected: SecStaticCode?
      guard
        SecStaticCodeCreateWithPath(expectedExecutable as CFURL, [], &expected) == errSecSuccess,
        let expected,
        SecStaticCodeCheckValidity(expected, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
          == errSecSuccess
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      var requirement: SecRequirement?
      guard SecCodeCopyDesignatedRequirement(expected, [], &requirement) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
          == errSecSuccess
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      var running: SecStaticCode?
      var information: CFDictionary?
      guard SecCodeCopyStaticCode(dynamic, [], &running) == errSecSuccess, let running,
        SecCodeCopySigningInformation(
          running, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
        let information = information as? [String: Any],
        let path = information[kSecCodeInfoMainExecutable as String] as? URL,
        path.resolvingSymlinksInPath() == expectedExecutable.resolvingSymlinksInPath()
      else { throw MCPFailure("PEER_NOT_TRUSTED") }
      var pid: pid_t = 0
      size = socklen_t(MemoryLayout<pid_t>.size)
      guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
        throw MCPFailure("PEER_NOT_TRUSTED")
      }
      return MCPSource(pid: pid)
    }
  }

  /// Only a fixed maximum of four connections may allocate a worker or buffer.
  /// A file descriptor is never reused until its worker has relinquished it.
  private final class MCPSocketLease: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    init(_ fd: Int32) { self.fd = fd }
    func cancel() {
      lock.lock()
      defer { lock.unlock() }
      if !cancelled {
        cancelled = true
        _ = Darwin.shutdown(fd, SHUT_RDWR)
      }
    }
    deinit { Darwin.close(fd) }
  }

  @MainActor
  final class MCPIPCServer {
    typealias Handler =
      @MainActor @Sendable (String, [String: MCPValue], MCPSource) async -> MCPResponse
    private var listener: MCPListener?
    static var socketURL: URL {
      if Bundle.main.object(forInfoDictionaryKey: "ConnDockMCPUseAppGroup") as? String == "YES" {
        let group = "86HC8YA388.com.ruohai.conndock.mcp"
        guard
          let folder = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group)
        else {
          return URL(fileURLWithPath: "/nonexistent/ConnDockMCPUnavailable.sock")
        }
        return folder.appendingPathComponent("mcp/ipc.sock")
      }
      return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(
        "tmp/conndock-mcp/ipc.sock")
    }
    func start(handler: @escaping Handler) throws {
      let executable = Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp")
      listener = try MCPListener(path: Self.socketURL.path, helper: executable, handler: handler)
    }
    func stop() {
      listener?.stop()
      listener = nil
    }
  }

  private final class MCPListener: @unchecked Sendable {
    private let lease: MCPSocketLease
    private let path: String
    private let helper: URL
    private let handler: MCPIPCServer.Handler
    private let queue = DispatchQueue(label: "ConnDock.MCP.IPC")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var stopped = false
    private var clients: [UUID: MCPSocketLease] = [:]

    init(path: String, helper: URL, handler: @escaping MCPIPCServer.Handler) throws {
      self.path = path
      self.helper = helper
      self.handler = handler
      let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var attributes = stat()
      guard lstat(folder.path, &attributes) == 0, attributes.st_uid == getuid(),
        attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o777 == 0o700
      else { throw MCPFailure("IPC_UNAVAILABLE") }
      if lstat(path, &attributes) == 0 {
        guard attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFSOCK else {
          throw MCPFailure("IPC_UNAVAILABLE")
        }
        // Only one App instance owns this endpoint; never unlink a live owner.
        let check = socket(AF_UNIX, SOCK_STREAM, 0)
        if check >= 0 {
          var address = try Self.address(path)
          let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              connect(check, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
          }
          Darwin.close(check)
          guard connected != 0, errno == ECONNREFUSED || errno == ENOENT else {
            throw MCPFailure("IPC_UNAVAILABLE")
          }
        }
        guard unlink(path) == 0 else { throw MCPFailure("IPC_UNAVAILABLE") }
      }
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw MCPFailure("IPC_UNAVAILABLE") }
      lease = MCPSocketLease(fd)
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      var address = try Self.address(path)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
        throw MCPFailure("IPC_UNAVAILABLE")
      }
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      self.source = source
      source.setEventHandler { [weak self] in self?.acceptClients() }
      source.resume()
    }
    deinit { stop() }
    func stop() {
      lock.lock()
      if stopped {
        lock.unlock()
        return
      }
      stopped = true
      let current = Array(clients.values)
      lock.unlock()
      source?.cancel()
      lease.cancel()
      for client in current { client.cancel() }
      _ = unlink(path)
    }
    private static func address(_ path: String) throws -> sockaddr_un {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bytes = Array(path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw MCPFailure("IPC_UNAVAILABLE")
      }
      withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
      return address
    }
    private func acceptClients() {
      while true {
        let fd = accept(lease.fd, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, 0)
        let client = MCPSocketLease(fd)
        let id = UUID()
        lock.lock()
        guard !stopped, clients.count < 4 else {
          lock.unlock()
          client.cancel()
          continue
        }
        clients[id] = client
        lock.unlock()
        Task.detached { [self, client] in
          defer { self.removeClient(id) }
          do {
            let peer = try MCPPeerVerifier.verify(fd, expectedExecutable: helper)
            let bytes = try Self.readFrame(fd)
            let request = try JSONDecoder().decode(MCPValue.self, from: bytes)
            guard case .object(let fields) = request,
              Set(fields.keys) == ["version", "id", "tool", "arguments"],
              fields["version"] == .number(1), let requestID = fields["id"]?.text,
              UUID(uuidString: requestID) != nil, let tool = fields["tool"]?.text,
              case .object(let arguments) = fields["arguments"]
            else { throw MCPFailure("INVALID_ARGUMENTS") }
            let task = Task { @MainActor in await handler(tool, arguments, peer) }
            let disconnect = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            disconnect.setEventHandler {
              var byte: UInt8 = 0
              let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
              if count >= 0 || (errno != EAGAIN && errno != EINTR) {
                task.cancel()
                client.cancel()
              }
            }
            disconnect.resume()
            let response = await task.value
            disconnect.cancel()
            try Self.writeFrame(fd, try JSONEncoder().encode(response))
          } catch {
            if let data = try? JSONEncoder().encode(
              MCPResponse.failure((error as? MCPFailure)?.code ?? "IPC_UNAVAILABLE"))
            {
              try? Self.writeFrame(fd, data)
            }
          }
          client.cancel()
        }
      }
    }
    private func removeClient(_ id: UUID) {
      lock.lock()
      defer { lock.unlock() }
      clients.removeValue(forKey: id)
    }
    static func readFrame(_ fd: Int32) throws -> Data {
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var header = [UInt8](repeating: 0, count: 4)
      try header.withUnsafeMutableBytes { try read(fd, into: $0) }
      let size = header.reduce(0) { ($0 << 8) | Int($1) }
      guard size > 0, size <= 65536 else { throw MCPFailure("INVALID_ARGUMENTS") }
      var bytes = Data(count: size)
      try bytes.withUnsafeMutableBytes { try read(fd, into: $0) }
      return bytes
    }
    private static func read(_ fd: Int32, into bytes: UnsafeMutableRawBufferPointer) throws {
      var offset = 0
      let deadline = Date().addingTimeInterval(5)
      while offset < bytes.count {
        guard Date() < deadline else { throw MCPFailure("TIMEOUT") }
        let count = recv(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MCPFailure("IPC_UNAVAILABLE") }
        offset += count
      }
    }
    static func writeFrame(_ fd: Int32, _ data: Data) throws {
      guard !data.isEmpty, data.count <= 1_048_576 else { throw MCPFailure("OUTPUT_LIMIT") }
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var noSignal: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      let size = UInt32(data.count)
      var frame = Data([
        UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255),
      ])
      frame.append(data)
      try frame.withUnsafeBytes { bytes in
        var offset = 0
        let deadline = Date().addingTimeInterval(5)
        while offset < bytes.count {
          guard Date() < deadline else { throw MCPFailure("TIMEOUT") }
          let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw MCPFailure("IPC_UNAVAILABLE") }
          offset += count
        }
      }
    }
  }
#endif
