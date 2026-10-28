#if os(macOS)
  import Darwin
  import Foundation
  import Security
  import SSHCoreBridge
  import XCTest

  @testable import ConnDockKit

  private actor MCPStdioTestClient {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var buffered = Data()
    init(helper: URL, socket: URL) throws {
      let incoming = Pipe()
      let outgoing = Pipe()
      input = incoming.fileHandleForWriting
      output = outgoing.fileHandleForReading
      process.executableURL = helper
      process.arguments = ["--socket", socket.path]
      process.standardInput = incoming
      process.standardOutput = outgoing
      process.standardError = FileHandle.nullDevice
      try process.run()
      try incoming.fileHandleForReading.close()
      try outgoing.fileHandleForWriting.close()
    }
    func stop() {
      try? input.close()
      if process.isRunning { process.terminate() }
      try? output.close()
    }
    func initialize() throws {
      _ = try exchange(
        .object([
          "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
          "params": .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object([
              "name": .string("ConnDock real integration test"), "version": .string("1"),
            ]),
          ]),
        ]))
      try write(
        .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
    }
    func call(_ tool: String, _ arguments: [String: MCPValue] = [:], id: Int) throws -> MCPValue {
      try exchange(
        .object([
          "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
          "params": .object(["name": .string(tool), "arguments": .object(arguments)]),
        ]))
    }
    private func write(_ value: MCPValue) throws {
      var bytes = try JSONEncoder().encode(value)
      bytes.append(10)
      try input.write(contentsOf: bytes)
    }
    private func exchange(_ request: MCPValue) throws -> MCPValue {
      try write(request)
      while true {
        if let newline = buffered.firstIndex(of: 10) {
          let line = buffered.prefix(upTo: newline)
          buffered.removeSubrange(...newline)
          return try JSONDecoder().decode(MCPValue.self, from: line)
        }
        guard buffered.count < 1_048_576 else { throw MCPFailure("TEST_STDIO_LIMIT") }
        var ready = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&ready, 1, 15000) > 0 else { throw MCPFailure("TEST_STDIO_TIMEOUT") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
        guard count > 0 else { throw MCPFailure("TEST_STDIO_CLOSED") }
        buffered.append(contentsOf: bytes.prefix(count))
      }
    }
  }

  extension MCPValue {
    fileprivate subscript(_ key: String) -> MCPValue? {
      if case .object(let object) = self { object[key] } else { nil }
    }
    fileprivate var array: [MCPValue]? { if case .array(let array) = self { array } else { nil } }
  }

  extension SSHIntegrationTests {
    func testMCPThroughHelperAndRealSSH() async throws {
      let configuration = try takeConfiguration()
      guard configuration.isolatedFixture == true, configuration.expectLinux == true,
        let directory = configuration.workingDirectory, let key = configuration.privateKey
      else {
        throw XCTSkip("Requires the isolated Linux fixture")
      }
      // Recover only one-shot fixture credentials left by a crashed test host.
      let preferenceFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Preferences")
      for file
        in (try? FileManager.default.contentsOfDirectory(
          at: preferenceFolder, includingPropertiesForKeys: nil)) ?? []
      {
        let name = file.deletingPathExtension().lastPathComponent
        let prefix = "ConnDock.MCPIntegration."
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        else { continue }
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name,
        ]
        _ = SecItemDelete(query as CFDictionary)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
      }
      let domain = "ConnDock.MCPIntegration.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
      let vault = KeychainCredentialStorage(service: domain)
      let library = try HostLibrary(memoryOnly: true, vault: vault, cleanupDefaults: defaults)
      let host = try await library.saveHost(
        HostDraft(
          displayName: "MCP real Linux fixture", hostname: configuration.host,
          port: configuration.port, username: configuration.username, authMethod: .ed25519),
        credential: .ed25519(privateKey: key, passphrase: configuration.passphrase),
        rememberCredential: true)
      let reference = try XCTUnwrap(host.credentialRef)
      addTeardownBlock {
        try await vault.delete(reference: reference)
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
      }
      let trust = HostTrustStore(defaults: defaults)
      try trust.remember(
        host: configuration.host, port: configuration.port, algorithm: "ssh-ed25519",
        fingerprint: configuration.fingerprint)
      let service = MCPService(
        library: library, defaults: defaults, executor: MCPRemoteExecutor(trustStore: trust))
      defer { service.shutdown() }
      let preferences = AppPreferences(defaults: defaults)
      service.configureUI(preferences: preferences)
      service.setEnabled(true)
      XCTAssertNil(service.failure)
      let client = try MCPStdioTestClient(helper: service.helperURL, socket: service.socketURL)
      addTeardownBlock { await client.stop() }
      try await client.initialize()
      let noHosts = try await client.call("list_hosts", id: 2)
      XCTAssertEqual(noHosts["result"]?["structuredContent"]?["data"]?["hosts"]?.array?.count, 0)
      service.setGrant(
        MCPHostGrant(
          host: host, tools: Set(MCPTool.configurable), roots: [directory],
          services: ["sshd.service"]), for: host.id)
      let listed = try await client.call("list_hosts", id: 3)
      XCTAssertEqual(
        listed["result"]?["structuredContent"]?["data"]?["hosts"]?.array?.first?["host_id"]?.text,
        host.id.uuidString)
      let hostArguments: [String: MCPValue] = ["host_id": .string(host.id.uuidString)]
      let metrics = try await client.call("get_server_metrics", hostArguments, id: 4)
      XCTAssertEqual(metrics["result"]?["isError"], .bool(false))
      XCTAssertGreaterThan(
        metrics["result"]?["structuredContent"]?["data"]?["memory_total"]?.number ?? 0, 0)
      let files = try await client.call(
        "sftp_list", hostArguments.merging(["path": .string(directory)]) { _, value in value },
        id: 5)
      XCTAssertEqual(files["result"]?["isError"], .bool(false))
      XCTAssertNotNil(files["result"]?["structuredContent"]?["data"]?["entries"]?.array)
      let status = try await client.call(
        "get_service_status",
        hostArguments.merging(["service_name": .string("sshd")]) { _, value in value }, id: 6)
      XCTAssertEqual(
        status["result"]?["structuredContent"]?["error"]?["code"]?.text, "UNSUPPORTED",
        "This Debian fixture does not run systemd")
      let command = "printf '__MCP_APPROVED__\\n'; printf '__MCP_STDERR__\\n' >&2; exit 7"
      let approved = Task {
        try await client.call(
          "ssh_exec",
          hostArguments.merging(["command": .string(command), "timeout": .number(10)]) { _, value in
            value
          }, id: 7)
      }
      try await mcpWait { !service.approvals.isEmpty }
      let exact = try XCTUnwrap(service.approvals.first)
      XCTAssertEqual(exact.command, command)
      XCTAssertEqual(exact.target.username, configuration.username)
      XCTAssertEqual(exact.timeout, 10)
      service.resolveApproval(exact.id, allow: true)
      let output = try await approved.value
      XCTAssertEqual(output["result"]?["structuredContent"]?["data"]?["exit_code"], .number(7))
      XCTAssertEqual(
        output["result"]?["structuredContent"]?["data"]?["stdout"]?.text, "__MCP_APPROVED__\n")
      XCTAssertEqual(
        output["result"]?["structuredContent"]?["data"]?["stderr"]?.text, "__MCP_STDERR__\n")
      let marker = "mcp-denied-\(UUID().uuidString)"
      let deniedCommand = "touch '\(directory)/\(marker)'"
      let denied = Task {
        try await client.call(
          "ssh_exec",
          hostArguments.merging(["command": .string(deniedCommand)]) { _, value in value }, id: 8)
      }
      try await mcpWait { !service.approvals.isEmpty }
      service.resolveApproval(try XCTUnwrap(service.approvals.first).id, allow: false)
      let denial = try await denied.value
      XCTAssertEqual(
        denial["result"]?["structuredContent"]?["error"]?["code"]?.text, "APPROVAL_DENIED")
      let afterDenial = try await client.call(
        "sftp_list", hostArguments.merging(["path": .string(directory)]) { _, value in value },
        id: 9)
      let names =
        afterDenial["result"]?["structuredContent"]?["data"]?["entries"]?.array?.compactMap {
          $0["name"]?.text
        } ?? []
      XCTAssertFalse(names.contains(marker), "Denied command must have no remote side effect")
      let unknown = try await client.call(
        "get_host_info", ["host_id": .string(UUID().uuidString)], id: 10)
      XCTAssertEqual(
        unknown["result"]?["structuredContent"]?["error"]?["code"]?.text, "HOST_NOT_AUTHORIZED")
      if configuration.runCodex == true {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ready = documents.appendingPathComponent(
          "MCPTestReady-\(configuration.runIdentifier).json")
        let done = documents.appendingPathComponent(
          "MCPTestDone-\(configuration.runIdentifier).json")
        defer {
          try? FileManager.default.removeItem(at: ready)
          try? FileManager.default.removeItem(at: done)
        }
        let endpoint: [String: String] = [
          "run_id": configuration.runIdentifier.uuidString, "helper": service.helperURL.path,
          "socket": service.socketURL.path, "host_id": host.id.uuidString,
        ]
        try JSONEncoder().encode(endpoint).write(to: ready, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ready.path)
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: done.path) && Date() < deadline {
          try await Task.sleep(for: .milliseconds(100))
        }
        let outcome = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: done))
        XCTAssertEqual(
          outcome["ok"], true,
          "Real Codex CLI must complete list_hosts and get_server_metrics; inspect phase5-codex.log"
        )
      }
      service.setEnabled(false)
      let disabled = try await client.call("list_hosts", id: 11)
      XCTAssertEqual(disabled["result"]?["isError"], .bool(true))
      let history = String(decoding: try JSONEncoder().encode(service.audit), as: UTF8.self)
      XCTAssertFalse(history.contains(command))
      XCTAssertFalse(history.contains(directory))
      XCTAssertFalse(history.contains(key))
    }

    private func mcpWait(_ predicate: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while !predicate() {
        guard Date() < deadline else { throw MCPFailure("TEST_TIMEOUT") }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
  }
#endif
