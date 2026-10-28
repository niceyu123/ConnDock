import Foundation
import SSHCoreBridge
import XCTest

@testable import ConnDockKit

@MainActor
final class TerminalLifecycleTests: XCTestCase {
  private func session() -> TerminalSession {
    TerminalSession(
      id: UUID(),
      target: ConnectionTarget(
        displayName: "Test", host: "example.invalid", port: 22, username: "test",
        usesPrivateKey: false))
  }

  func testClosingSessionRejectsLateConnectedAndOutputEvents() {
    let terminal = session()
    terminal.close()
    terminal.consume([.stateChanged(state: .connected), .output(data: Data([65, 66, 67]))])
    XCTAssertEqual(terminal.state, .disconnected)
    XCTAssertFalse(terminal.isConnected)
    XCTAssertEqual(terminal.receivedBytes, 0)
  }

  func testEndedEventCannotBeUndoneWithinTheSameEventBatch() {
    let terminal = session()
    terminal.consume([
      .ended(reason: .remote, error: nil, exitStatus: 0), .stateChanged(state: .connected),
      .output(data: Data([65])),
    ])
    XCTAssertEqual(terminal.state, .disconnected)
    XCTAssertEqual(terminal.receivedBytes, 0)
  }

  func testBackgroundBlocksInputAndRequiresValidationOnReturn() {
    let terminal = session()
    terminal.consume([.stateChanged(state: .connected)])
    XCTAssertTrue(terminal.isConnected)
    terminal.enterBackground()
    XCTAssertTrue(terminal.isSuspended)
    XCTAssertFalse(terminal.isConnected)
    terminal.restoreForeground()
    XCTAssertFalse(
      terminal.isConnected, "A missing real transport must never be treated as verified")
    XCTAssertFalse(terminal.isActive)
    XCTAssertEqual(terminal.localErrorKey, "ssh.error.resumeFailed")
  }

  func testBackgroundCancelsPendingAuthenticationAndClosedSessionCannotResume() {
    let terminal = session()
    terminal.consume([.stateChanged(state: .authenticating)])
    terminal.enterBackground()
    terminal.restoreForeground()
    terminal.consume([.stateChanged(state: .connected)])
    XCTAssertFalse(terminal.isActive)
    XCTAssertEqual(terminal.state, .disconnected)
  }

  func testDisconnectingSessionDoesNotReportALateSuccessfulConnection() {
    let terminal = session()
    var connections = 0
    terminal.onConnected = { connections += 1 }
    terminal.disconnect()
    terminal.consume([.stateChanged(state: .connected)])
    XCTAssertEqual(connections, 0)
    XCTAssertFalse(terminal.isConnected)
  }

  func testNativeSurfaceDoesNotRetainItsClosedSession() {
    weak var released: TerminalSession?
    var retainedSurface: TerminalSurface?
    do {
      let terminal = session()
      released = terminal
      retainedSurface = terminal.surface
      terminal.close()
    }
    XCTAssertNil(released)
    XCTAssertNotNil(retainedSurface)
  }
}
