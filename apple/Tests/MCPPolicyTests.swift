#if os(macOS)
  import Foundation
  import XCTest

  @testable import ConnDockKit

  @MainActor
  final class MCPPolicyTests: XCTestCase {
    func testDefaultsDenyAndGrantIsBoundToExactHostIdentity() throws {
      let host = StoredHost(
        displayName: "Test", hostname: "example.invalid", port: 22, username: "tester",
        authMethod: .password)
      var policy = MCPPolicy()
      XCTAssertFalse(policy.enabled)
      XCTAssertFalse(policy.allows(.getHostInfo, host: host))
      policy.enabled = true
      policy.grants[host.id.uuidString] = MCPHostGrant(host: host, tools: [.getHostInfo])
      XCTAssertTrue(policy.allows(.getHostInfo, host: host))
      XCTAssertFalse(policy.allows(.sshExec, host: host))
      host.username = "root"
      XCTAssertFalse(policy.allows(.getHostInfo, host: host))
    }

    func testStrictInputsRejectAlternativeTargetsAndUnsafeCommands() throws {
      let id = UUID().uuidString
      XCTAssertThrowsError(
        try MCPRequest.parse(
          tool: "get_host_info",
          arguments: [
            "host_id": .string(id), "hostname": .string("other.invalid"),
          ]))
      for command in ["", "pwd\u{0}", "echo \u{202E}danger", String(repeating: "a", count: 8193)] {
        XCTAssertThrowsError(
          try MCPRequest.parse(
            tool: "ssh_exec",
            arguments: [
              "host_id": .string(id), "command": .string(command),
            ]))
      }
      for timeout in [0.0, 60.5, 61.0] {
        XCTAssertThrowsError(
          try MCPRequest.parse(
            tool: "ssh_exec",
            arguments: [
              "host_id": .string(id), "command": .string("pwd"), "timeout": .number(timeout),
            ]))
      }
      let request = try MCPRequest.parse(
        tool: "ssh_exec",
        arguments: [
          "host_id": .string(id), "command": .string("printf '中文\\n'; pwd\n"),
        ])
      XCTAssertEqual(request.timeout, 20)
      XCTAssertEqual(request.command, "printf '中文\\n'; pwd\n")
    }

    func testDirectoryPolicyRejectsTraversalPrefixesAndSensitivePaths() throws {
      XCTAssertTrue(MCPPathPolicy.allows("/srv/www/logs", roots: ["/srv/www"]))
      for path in ["/srv/www2", "/srv/www/../secret", "/srv/www/.ssh", "/proc/1", "relative"] {
        XCTAssertFalse(MCPPathPolicy.allows(path, roots: ["/srv/www"]))
      }
      XCTAssertFalse(MCPPathPolicy.allows("/srv/www", roots: []))
    }

    func testServiceNamesCannotBecomeShellFragments() throws {
      for name in ["sshd;id", "--help", "../sshd", "ssh\nwhoami", ""] {
        XCTAssertFalse(MCPRequest.validService(name))
      }
      XCTAssertTrue(MCPRequest.validService("sshd.service"))
      XCTAssertTrue(MCPRequest.validService("app@worker.service"))
    }
  }
#endif
