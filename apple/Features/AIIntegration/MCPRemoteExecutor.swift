#if os(macOS)
  import Foundation
  import SSHCoreBridge

  /// The helper never receives credentials. Every invocation owns a separate
  /// authenticated connection; no bytes are injected into an interactive tab.
  @MainActor
  final class MCPRemoteExecutor: MCPExecuting {
    private let trustStore: HostTrustStore
    init(trustStore: HostTrustStore? = nil) { self.trustStore = trustStore ?? HostTrustStore() }

    func execute(_ invocation: MCPInvocation, control: MCPExecutionControl) async throws -> MCPValue
    {
      try control.check()
      let target = invocation.target
      let options = invocation.library.connectionOptions(for: invocation.host.id)
      guard !options.allowInteractive && invocation.host.authMethod.needsCredential else {
        throw MCPFailure("INTERACTIVE_AUTH_REQUIRED")
      }
      var jumpConnection: SshConnection?
      if let jumpID = options.jumpHostID {
        guard let jump = invocation.library.host(jumpID), jumpID != invocation.host.id,
          invocation.library.connectionOptions(for: jumpID).jumpHostID == nil,
          !invocation.library.connectionOptions(for: jumpID).allowInteractive,
          jump.authMethod.needsCredential
        else {
          throw MCPFailure("JUMP_UNAVAILABLE")
        }
        let jumpTarget = jump.target
        let jumpRevision = jump.syncRevision
        guard let fp = try trustStore.fingerprint(host: jumpTarget.host, port: jumpTarget.port),
          let credential = try await invocation.library.credential(
            for: jump, allowsUserInteraction: false)
        else {
          throw MCPFailure("JUMP_UNAVAILABLE")
        }
        try control.check()
        guard invocation.library.host(jumpID)?.syncRevision == jumpRevision else {
          throw MCPFailure("JUMP_UNAVAILABLE")
        }
        let parent = try connectAdvanced(
          request: ConnectionRequest(
            host: jumpTarget.host, port: jumpTarget.port, username: jumpTarget.username,
            trustedFingerprint: fp, columns: 80, rows: 24, timeoutSeconds: 20),
          authentication: credential.request,
          transportOnly: true, allowInteractive: false, jump: nil)
        control.connection = parent
        do { try await waitForTransport(parent, control: control) } catch {
          parent.disconnect()
          throw error
        }
        jumpConnection = parent
      }
      defer { jumpConnection?.disconnect() }
      let fingerprint: String
      do {
        guard let saved = try trustStore.fingerprint(host: target.host, port: target.port) else {
          throw MCPFailure("HOST_TRUST_REQUIRED")
        }
        fingerprint = saved
      } catch let error as MCPFailure { throw error } catch {
        throw MCPFailure("HOST_TRUST_FAILED")
      }
      let credential: SavedCredential
      do {
        guard
          let saved = try await invocation.library.credential(
            for: invocation.host, allowsUserInteraction: false)
        else {
          throw MCPFailure("CREDENTIAL_UNAVAILABLE")
        }
        credential = saved
      } catch { throw MCPFailure("CREDENTIAL_UNAVAILABLE") }
      try control.check()
      let connection: SshConnection
      do {
        connection = try connectAdvanced(
          request: ConnectionRequest(
            host: target.host, port: target.port, username: target.username,
            trustedFingerprint: fingerprint, columns: 80, rows: 24, timeoutSeconds: 20),
          authentication: credential.request, transportOnly: true, allowInteractive: false,
          jump: jumpConnection)
      } catch { throw MCPFailure("CONNECTION_FAILED") }
      control.connection = connection
      defer {
        connection.disconnect()
        control.connection = nil
      }
      try await waitForTransport(connection, control: control)
      try control.check()
      do {
        return try await executeTool(invocation, connection: connection, control: control)
      }
    }

    private func waitForTransport(_ connection: SshConnection, control: MCPExecutionControl)
      async throws
    {
      let deadline = Date().addingTimeInterval(25)
      var connected = false
      while !connected {
        try control.check()
        guard Date() < deadline else { throw MCPFailure("TIMEOUT") }
        for event in connection.pollEvents() {
          switch event {
          case .stateChanged(let state): if state == .connected { connected = true }
          case .hostKey: throw MCPFailure("HOST_TRUST_REQUIRED")
          case .authenticationChallenge: throw MCPFailure("INTERACTIVE_AUTH_REQUIRED")
          case .ended(_, let error, _):
            switch error {
            case .hostKeyChanged, .hostKeyRejected: throw MCPFailure("HOST_TRUST_FAILED")
            case .authenticationFailed, .invalidPrivateKey, .unsupportedPrivateKey:
              throw MCPFailure("AUTHENTICATION_FAILED")
            case .timeout: throw MCPFailure("TIMEOUT")
            default: throw MCPFailure("CONNECTION_FAILED")
            }
          case .output: break
          }
        }
        if !connected { try await Task.sleep(for: .milliseconds(16)) }
      }
    }
    private func executeTool(
      _ invocation: MCPInvocation, connection: SshConnection, control: MCPExecutionControl
    ) async throws -> MCPValue {
      do {
        switch invocation.request.tool {
        case .getServerMetrics:
          let monitor = try connection.startLinuxMonitor()
          defer { monitor.stop() }
          _ = try await monitor.sample()
          try await Task.sleep(for: .milliseconds(300))
          try control.check()
          let sample = try await monitor.sample()
          return .object([
            "system": .string(sample.system), "uptime_seconds": .number(sample.uptimeSeconds),
            "cpu_percent": sample.cpuPercent.map(MCPValue.number) ?? .null,
            "memory_total": .number(Double(sample.memoryTotal)),
            "memory_used": .number(Double(sample.memoryUsed)),
            "disk_total": .number(Double(sample.diskTotal)),
            "disk_used": .number(Double(sample.diskUsed)),
            "disk_percent": .number(sample.diskPercent),
            "receive_bytes_per_second": sample.receiveBytesPerSecond.map(MCPValue.number) ?? .null,
            "transmit_bytes_per_second": sample.transmitBytesPerSecond.map(MCPValue.number)
              ?? .null,
          ])
        case .getServiceStatus:
          let status = try await connection.serviceStatus(
            serviceName: invocation.request.serviceName ?? "", operation: control.operation)
          return .object([
            "name": .string(status.name), "load_state": .string(status.loadState),
            "active_state": .string(status.activeState), "sub_state": .string(status.subState),
            "unit_file_state": .string(status.unitFileState),
            "active_enter_timestamp": .string(status.activeEnterTimestamp),
          ])
        case .sftpList:
          let files = try await connection.openFilesCancellable(operation: control.operation)
          defer { files.close() }
          let listing = try await files.listAuthorizedDirectory(
            path: invocation.request.path ?? "", allowedRoots: invocation.grant.roots,
            operation: control.operation)
          return .object([
            "path": .string(listing.path),
            "entries": .array(
              listing.entries.map { entry in
                let kind: String
                switch entry.kind {
                case .directory: kind = "directory"
                case .regular: kind = "file"
                case .symlink: kind = "symlink"
                case .other: kind = "other"
                }
                return .object([
                  "name": .string(entry.name), "kind": .string(kind),
                  "size": entry.size.map { .number(Double($0)) } ?? .null,
                  "modified_seconds": entry.modifiedSeconds.map { .number(Double($0)) } ?? .null,
                ])
              }),
          ])
        case .sshExec:
          let output = try await connection.executeCommand(
            command: invocation.request.command ?? "", timeoutSeconds: invocation.request.timeout,
            operation: control.operation)
          return .object([
            "exit_code": output.exitCode.map { .number(Double($0)) } ?? .null,
            "stdout": .string(String(decoding: output.stdout, as: UTF8.self)),
            "stderr": .string(String(decoding: output.stderr, as: UTF8.self)),
            "truncated": .bool(output.truncated), "output_limit_bytes": .number(65536),
          ])
        case .listHosts, .getHostInfo: throw MCPFailure("UNKNOWN_TOOL")
        }
      } catch let error as MCPFailure { throw error } catch RemoteFailure.Failure(let code) {
        switch code {
        case .cancelled: throw MCPFailure("CANCELLED")
        case .timeout: throw MCPFailure("TIMEOUT")
        case .permissionDenied: throw MCPFailure("PERMISSION_DENIED")
        case .invalidPath: throw MCPFailure("PATH_NOT_AUTHORIZED")
        case .unsupported: throw MCPFailure("UNSUPPORTED")
        case .directoryTooLarge, .outputLimit: throw MCPFailure("OUTPUT_LIMIT")
        case .notFound: throw MCPFailure("NOT_FOUND")
        default: throw MCPFailure("REMOTE_FAILURE")
        }
      }
    }
  }
#endif
