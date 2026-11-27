import SwiftUI
import UniformTypeIdentifiers

private struct EncryptedConfigurationDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  let data: Data

  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let bytes = configuration.file.regularFileContents,
      bytes.count <= ConfigurationArchiveCryptor.maximumFileBytes
    else { throw ConfigurationArchiveError.limit }
    data = bytes
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct ConfigurationBackupOperation: Identifiable {
  let id = UUID()
  var name: String?
  var data: Data?
}

struct ConfigurationBackupSection: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @State private var showImporter = false
  @State private var reading = false
  @State private var readingTask: Task<Void, Never>?
  @State private var operation: ConfigurationBackupOperation?
  @State private var errorKey: String?

  var body: some View {
    Section {
      exportButton
      Button {
        showImporter = true
      } label: {
        SymbolLabel(key: "backup.import", symbol: "square.and.arrow.down")
      }
      .accessibilityIdentifier("importConfiguration")
      if reading { ProgressView(preferences.text("backup.reading")) }
    } header: {
      Copy("backup.title")
    } footer: {
      Copy("backup.description").fixedSize(horizontal: false, vertical: true)
    }
    .disabled(reading || workspace.library == nil || workspace.library?.isBusy == true)
  }

  // Form flattens Section into rows. Present from a concrete row so the
  // system presentation remains attached to a visible view in the hierarchy.
  private var exportButton: some View {
    Button {
      operation = ConfigurationBackupOperation()
    } label: {
      SymbolLabel(key: "backup.export", symbol: "square.and.arrow.up")
    }
    .accessibilityIdentifier("exportConfiguration")
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
      read(result)
    }
    .sheet(item: $operation) { ConfigurationBackupSheet(operation: $0) }
    .alert(
      preferences.text("backup.title"),
      isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })
    ) {
      Button(preferences.text("action.done")) { errorKey = nil }
    } message: {
      if let errorKey { Copy(errorKey) }
    }
    .onDisappear { readingTask?.cancel() }
  }

  private func read(_ result: Result<URL, Error>) {
    guard case .success(let url) = result else {
      if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
        errorKey = "backup.error.read"
      }
      return
    }
    reading = true
    readingTask = Task {
      defer { reading = false }
      do {
        let data = try await Task.detached(priority: .userInitiated) {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
          guard properties.isRegularFile == true else { throw ConfigurationArchiveError.read }
          let limit = ConfigurationArchiveCryptor.maximumFileBytes
          guard (properties.fileSize ?? 0) <= limit else { throw ConfigurationArchiveError.limit }
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          var result = Data()
          while result.count <= limit {
            let chunk = try handle.read(upToCount: limit + 1 - result.count) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
          }
          guard result.count <= limit else { throw ConfigurationArchiveError.limit }
          return result
        }.value
        try Task.checkCancellation()
        operation = ConfigurationBackupOperation(name: url.lastPathComponent, data: data)
      } catch {
        guard !Task.isCancelled else { return }
        errorKey = (error as? ConfigurationArchiveError)?.localizationKey ?? "backup.error.read"
      }
    }
  }
}

private struct ConfigurationBackupSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let operation: ConfigurationBackupOperation
  @State private var password = ""
  @State private var confirmation = ""
  @State private var busy = false
  @State private var work: Task<Void, Never>?
  @State private var snapshot: ConfigurationSnapshot?
  @State private var encryptedDocument: EncryptedConfigurationDocument?
  @State private var showExporter = false
  @State private var errorKey: String?
  @State private var report: ConfigurationImportReport?
  @State private var exported = false

  private var importing: Bool { operation.data != nil }
  private var finished: Bool { report != nil || exported }
  private var canProceed: Bool {
    !busy && !finished && workspace.library != nil && workspace.library?.isBusy == false
      && (snapshot != nil
        || (importing ? !password.isEmpty : password.count >= 12 && password == confirmation)
          && password.utf8.count <= 1024)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let name = operation.name { Text(verbatim: name).font(.headline) }
          Copy("backup.description").foregroundStyle(.secondary)
          Copy(importing ? "backup.importDetail" : "backup.passwordDetail")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !finished && snapshot == nil {
          Section {
            SecureField(preferences.text("backup.password"), text: $password)
              .textContentType(importing ? .password : .newPassword)
              .accessibilityIdentifier("backupPassword")
            if !importing {
              SecureField(preferences.text("backup.confirmPassword"), text: $confirmation)
                .textContentType(.newPassword)
                .accessibilityIdentifier("backupConfirmPassword")
              if !confirmation.isEmpty && password != confirmation {
                Copy("backup.mismatch").foregroundStyle(.red)
              }
            }
          }
        }
        if let snapshot, report == nil {
          Section {
            countRow("backup.hosts", snapshot.hosts.count)
            countRow("backup.groups", snapshot.groups.count)
            countRow("backup.credentials", snapshot.credentialCount)
            Copy("backup.duplicatesDetail").foregroundStyle(.secondary)
          } header: {
            Copy("backup.preview")
          }
          Section {
            ForEach(snapshot.hosts, id: \.id) { host in
              VStack(alignment: .leading, spacing: 4) {
                Text(
                  verbatim: host.configuration.displayName.isEmpty
                    ? host.configuration.hostname : host.configuration.displayName)
                Text(
                  verbatim:
                    "\(host.configuration.username)@\(host.configuration.hostname):\(host.configuration.port)"
                )
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                Copy(host.configuration.authMethod.titleKey).font(.caption)
              }
              .padding(.vertical, 4)
            }
          } header: {
            Copy("backup.hosts")
          }
        }
        if let report {
          Section {
            countRow("backup.importedHosts", report.importedHosts)
            countRow("backup.importedGroups", report.importedGroups)
            countRow("backup.importedCredentials", report.importedCredentials)
            countRow("backup.skippedHosts", report.skippedHosts)
          } header: {
            Copy("backup.complete")
          }
          .accessibilityIdentifier("configurationImportResult")
        }
        if exported { Copy("backup.exported").accessibilityIdentifier("configurationExportResult") }
        if busy { ProgressView(preferences.text("backup.processing")) }
        if let errorKey { Copy(errorKey).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .disabled(busy)
      .navigationTitle(preferences.text("backup.title"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(preferences.text(finished ? "action.done" : "action.cancel")) { dismiss() }
            .disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          if !finished {
            Button(
              preferences.text(
                importing
                  ? (snapshot == nil ? "backup.unlock" : "backup.confirmImport")
                  : "backup.exportAction")
            ) {
              proceed()
            }
            .disabled(!canProceed)
            .accessibilityIdentifier("backupProceed")
          }
        }
      }
    }
    .interactiveDismissDisabled(busy || showExporter)
    .fileExporter(
      isPresented: $showExporter, document: encryptedDocument, contentType: .json,
      defaultFilename: "ConnDock-Backup"
    ) { result in
      encryptedDocument = nil
      switch result {
      case .success: exported = true
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { errorKey = "backup.error.write" }
      }
    }
    .onDisappear {
      work?.cancel()
      password = ""
      confirmation = ""
      snapshot = nil
      encryptedDocument = nil
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        work?.cancel()
        password = ""
        confirmation = ""
        snapshot = nil
        encryptedDocument = nil
        showExporter = false
      }
    }
    #if os(macOS)
      .frame(width: 620, height: 640)
    #endif
  }

  private func countRow(_ key: String, _ count: Int) -> some View {
    LabeledContent(preferences.text(key)) { Text(count, format: .number) }
  }

  private func proceed() {
    guard canProceed, let library = workspace.library else { return }
    busy = true
    errorKey = nil
    let backupPassword = password
    work = Task {
      defer { busy = false }
      do {
        if let snapshot {
          report = try await library.importConfiguration(snapshot)
          self.snapshot = nil
        } else if let encrypted = operation.data {
          let decoded = try await Task.detached(priority: .userInitiated) {
            try ConfigurationSnapshot.decode(
              ConfigurationArchiveCryptor.open(encrypted, password: backupPassword))
          }.value
          try Task.checkCancellation()
          snapshot = decoded
          password = ""
        } else {
          let captured = try await ConfigurationSnapshot.capture(from: library)
          let encrypted = try await Task.detached(priority: .userInitiated) {
            try ConfigurationArchiveCryptor.seal(captured.encoded(), password: backupPassword)
          }.value
          try Task.checkCancellation()
          password = ""
          confirmation = ""
          encryptedDocument = EncryptedConfigurationDocument(data: encrypted)
          showExporter = true
        }
      } catch {
        guard !Task.isCancelled else { return }
        errorKey =
          (error as? ConfigurationArchiveError)?.localizationKey
          ?? (error as? HostLibraryError)?.localizationKey ?? "backup.error.invalid"
      }
    }
  }
}
