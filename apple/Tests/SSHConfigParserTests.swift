import Foundation
import XCTest

#if canImport(ConnDockKit)
  @testable import ConnDockKit
#endif

final class SSHConfigParserTests: XCTestCase {
  func testQuotedValuesCommentsAndEqualsProduceConnectionWithoutReadingIdentityFile() throws {
    let result = try SSHConfigParser.parse(
      #"""
      Host "office" other
        HostName = "example.invalid" # endpoint
        User="engineer"
        Port = 2222
        IdentityFile "~/keys/my # private key"
      """#)
    XCTAssertEqual(result.entries.map(\.alias), ["office", "other"])
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(entry.hostname, "example.invalid")
    XCTAssertEqual(entry.username, "engineer")
    XCTAssertEqual(entry.port, 2222)
    XCTAssertTrue(entry.requiresPrivateKey)
    XCTAssertTrue(entry.canImport)
  }

  func testFirstValueWinsAcrossGlobalExactAndWildcardBlocks() throws {
    let result = try SSHConfigParser.parse(
      """
      User global
      Host prod-* !prod-excluded
        Port 2200
      Host prod-one prod-excluded
        User later
        HostName first.invalid
        HostName second.invalid
        Port 2300
      Host *
        Port 24
      """)
    XCTAssertEqual(result.entries.map(\.alias), ["prod-one", "prod-excluded"])
    XCTAssertEqual(result.entries.map(\.hostname), ["first.invalid", "first.invalid"])
    XCTAssertEqual(result.entries.map(\.username), ["global", "global"])
    XCTAssertEqual(result.entries.map(\.port), [2200, 2300])
    XCTAssertTrue(result.entries.allSatisfy(\.canImport))
  }

  func testWildcardOnlyBlocksDoNotCreateHostsAndDuplicateAliasesUseFirstDefinition() throws {
    let result = try SSHConfigParser.parse(
      """
      Host * *.invalid !skip
        User engineer
      Host Web web
        HostName first.invalid
      Host WEB
        HostName second.invalid
      """)
    XCTAssertEqual(result.entries.map(\.alias), ["Web"])
    XCTAssertEqual(result.entries.first?.hostname, "first.invalid")
  }

  func testProxyAndUnknownOptionsBlockOnlyMatchingEntries() throws {
    let result = try SSHConfigParser.parse(
      """
      User engineer
      Host indirect
        ProxyJump gateway
      Host direct
        HostName direct.invalid
      Host other
        CustomConnectionMode enabled
      Host x11
        ForwardX11 yes
      """)
    XCTAssertEqual(result.entries.map(\.canImport), [false, true, false, false])
    XCTAssertEqual(try XCTUnwrap(result.entries.first).issues.first?.directive, "proxyjump")
  }

  func testIncludeAndMatchCannotSilentlyImportDirectConnections() throws {
    for directive in ["Include ~/.ssh/conf.d/*", "Match exec \"touch /tmp/never\""] {
      let result = try SSHConfigParser.parse(
        "User engineer\nHost earlier\nHostName before.invalid\n\(directive)\nHost later\n")
      XCTAssertFalse(result.entries.isEmpty)
      XCTAssertTrue(result.entries.allSatisfy { !$0.canImport })
      XCTAssertTrue(result.diagnostics.contains { $0.key == "sshConfig.issue.context" })
    }
  }

  func testInvalidFirstValuesAreNotReplacedByLaterDefaults() throws {
    for value in ["0", "65536", "-1", "+22", "22junk", "\"\""] {
      let result = try SSHConfigParser.parse(
        "User engineer\nHost bad\nPort \(value)\nHost *\nPort 22\n")
      XCTAssertEqual(result.entries.count, 1)
      let entry = try XCTUnwrap(result.entries.first)
      XCTAssertFalse(entry.canImport, value)
      XCTAssertTrue(entry.issues.contains { $0.key == "sshConfig.issue.port" })
    }
  }

  func testMissingUsernameRequiresExplicitDefaultAndTokenExpansionIsBlocked() throws {
    let missing = try SSHConfigParser.parse("Host plain\n")
    XCTAssertFalse(try XCTUnwrap(missing.entries.first).canImport)
    let resolved = try SSHConfigParser.parse("Host plain\n", defaultUsername: "engineer")
    XCTAssertEqual(resolved.entries.first?.username, "engineer")
    XCTAssertTrue(try XCTUnwrap(resolved.entries.first).canImport)
    for directive in ["HostName %h.example", "User ${REMOTE_USER}", "HostName bad/name"] {
      let result = try SSHConfigParser.parse("User engineer\nHost invalid\n\(directive)\n")
      if directive.hasPrefix("User") {
        // First obtained User already wins, so an inactive later value has no effect.
        XCTAssertTrue(try XCTUnwrap(result.entries.first).canImport)
      } else {
        XCTAssertFalse(try XCTUnwrap(result.entries.first).canImport)
      }
    }
    let userToken = try SSHConfigParser.parse("Host invalid\nUser ${REMOTE_USER}\n")
    XCTAssertFalse(try XCTUnwrap(userToken.entries.first).canImport)
  }

  func testMalformedSyntaxAndUnsafeHostPatternsBlockInsteadOfChangingScope() throws {
    for invalid in ["Host \"unterminated", "Host", "Host bad,other", "Port 22 23"] {
      let result = try SSHConfigParser.parse("User engineer\nHost safe\n\(invalid)\nHost later\n")
      XCTAssertTrue(result.entries.allSatisfy { !$0.canImport }, invalid)
      XCTAssertFalse(result.diagnostics.isEmpty, invalid)
    }
  }

  func testInputAndEntryLimitsRejectWholeImport() throws {
    XCTAssertThrowsError(try SSHConfigParser.parse(String(repeating: "#", count: 262_145)))
    let tooMany = (0...256).map { "Host host\($0)" }.joined(separator: "\n")
    XCTAssertThrowsError(try SSHConfigParser.parse(tooMany))
    XCTAssertThrowsError(try SSHConfigParser.parse("Host valid\nUser \u{0000}bad"))
    XCTAssertThrowsError(try SSHConfigParser.parse(String(repeating: "\n", count: 8193)))
  }

  func testMultipleIdentityFilesOnlyProvideAnAuthenticationHint() throws {
    let multiple = try SSHConfigParser.parse(
      "User engineer\nHost named\nIdentityFile none\nIdentityFile ~/.ssh/not-read\n")
    XCTAssertTrue(try XCTUnwrap(multiple.entries.first).requiresPrivateKey)
    let disabled = try SSHConfigParser.parse("User engineer\nHost named\nIdentityFile none\n")
    XCTAssertFalse(try XCTUnwrap(disabled.entries.first).requiresPrivateKey)
    let empty = try SSHConfigParser.parse("User engineer\nHost named\nIdentityFile \"\"\n")
    XCTAssertFalse(try XCTUnwrap(empty.entries.first).canImport)
  }

  func testDiagnosticsRemainBoundedForManyUnsupportedDirectives() throws {
    let options = String(repeating: "ProxyCommand never-run\n", count: 1000)
    let result = try SSHConfigParser.parse("User engineer\nHost named\n" + options)
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertFalse(entry.canImport)
    XCTAssertLessThanOrEqual(entry.issues.count, 16)
    let malformed = try SSHConfigParser.parse(
      "User engineer\nHost named\n" + String(repeating: "Invalid ??? \"\n", count: 1000))
    XCTAssertFalse(try XCTUnwrap(malformed.entries.first).canImport)
    XCTAssertLessThanOrEqual(malformed.diagnostics.count, 64)
  }

  func testQuotedHostnamePunctuationCannotBecomeAnUnintendedEndpoint() throws {
    for hostname in ["'bad.invalid'", "bad\\\"host", "bad;host", "bad(host)"] {
      let result = try SSHConfigParser.parse("User engineer\nHost named\nHostName \(hostname)\n")
      XCTAssertFalse(try XCTUnwrap(result.entries.first).canImport, hostname)
    }
  }
}
