import CloudKit
import Foundation
import Security

enum SyncTransportEvent: Sendable {
  case state(Data)
  case records([SyncRecordSnapshot])
  case deleted([SyncIdentity])
  case accountChanged
  case zoneRemoved
}

@MainActor
struct SyncTransportHandlers {
  let records: ([String]) throws -> [SyncRecordSnapshot]
  let event: (SyncTransportEvent) async throws -> Void
  var expectsExistingZone = false
}

@MainActor
protocol CloudSyncTransport: AnyObject {
  func accountIdentifier() async throws -> String
  func start(state: Data?, handlers: SyncTransportHandlers) throws
  func enqueue(_ identities: [SyncIdentity])
  func synchronize() async throws
  func stop()
  func deleteZone() async throws
}

struct CloudSyncConfiguration: Sendable {
  let containerIdentifier: String?
  var isConfigured: Bool { containerIdentifier != nil }

  static var current: Self {
    let bundle = Bundle.main
    guard ProcessInfo.processInfo.environment["CONNDOCK_UI_TESTING"] != "1",
      (bundle.object(forInfoDictionaryKey: "ConnDockCloudKitEnabled") as? NSString)?.boolValue
        == true,
      let identifier = bundle.object(forInfoDictionaryKey: "ConnDockCloudKitContainer") as? String,
      identifier.hasPrefix("iCloud."), identifier.count > 7,
      let team = bundle.object(forInfoDictionaryKey: "ConnDockCloudKitTeam") as? String,
      team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    else { return Self(containerIdentifier: nil) }
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil),
        let services = SecTaskCopyValueForEntitlement(
          task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
        services.contains("CloudKit"),
        let identifiers = SecTaskCopyValueForEntitlement(
          task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
        identifiers.contains(identifier)
      else { return Self(containerIdentifier: nil) }
    #endif
    return Self(containerIdentifier: identifier)
  }
}

func cloudSyncFailure(_ error: Error) -> CloudSyncFailure {
  if let failure = error as? CloudSyncFailure { return failure }
  if error is CancellationError { return .cancelled }
  if error is HostLibraryError { return .localStore }
  guard let error = error as? CKError else { return .server }
  switch error.code {
  case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy, .requestRateLimited:
    return .network
  case .notAuthenticated: return .signedOut
  case .permissionFailure, .managedAccountRestricted: return .restricted
  case .quotaExceeded: return .quota
  case .badContainer, .missingEntitlement, .badDatabase, .invalidArguments: return .configuration
  case .zoneNotFound, .userDeletedZone: return .zoneRemoved
  case .operationCancelled: return .cancelled
  default: return .server
  }
}
