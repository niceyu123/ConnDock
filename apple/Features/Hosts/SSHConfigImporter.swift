import Foundation

struct SSHConfigImportReport {
  var importedCount = 0
  var skippedCount = 0
  var remainingCount = 0
  var errorKey: String?
}

enum SSHConfigImporter {
  @MainActor
  static func save(_ entries: [SSHConfigEntry], selectedIDs: Set<String>, to library: HostLibrary)
    async -> SSHConfigImportReport
  {
    guard entries.count <= SSHConfigParser.maximumEntries else {
      return SSHConfigImportReport(
        remainingCount: selectedIDs.count, errorKey: "sshConfig.error.limit")
    }
    let selected = entries.filter { selectedIDs.contains($0.id) }
    var report = SSHConfigImportReport(remainingCount: selected.count)
    for entry in selected {
      guard !Task.isCancelled else {
        report.errorKey = "sshConfig.error.cancelled"
        break
      }
      // Recheck against the current library for every row: the preview is not a lock.
      guard entry.canImport, !isDuplicate(entry, in: library) else {
        report.skippedCount += 1
        report.remainingCount -= 1
        continue
      }
      let draft = HostDraft(
        displayName: entry.alias, hostname: entry.hostname, port: entry.port,
        username: entry.username, authMethod: entry.requiresPrivateKey ? .ed25519 : .password)
      do {
        _ = try await library.saveHost(draft)
        report.importedCount += 1
        report.remainingCount -= 1
      } catch {
        // Earlier commits remain durable; report them separately and stop this batch.
        report.errorKey =
          (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
        break
      }
    }
    return report
  }

  @MainActor
  static func isDuplicate(_ entry: SSHConfigEntry, in library: HostLibrary) -> Bool {
    library.hosts.contains {
      $0.title.caseInsensitiveCompare(entry.alias) == .orderedSame
        || ($0.hostname.caseInsensitiveCompare(entry.hostname) == .orderedSame
          && $0.port == Int(entry.port) && $0.username == entry.username)
    }
  }
}
