import SwiftUI
import UniformTypeIdentifiers

private struct SSHConfigDocument: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let source: String
}

/// Self-contained entry point shared by the sidebar and the iPhone host toolbar.
struct SSHConfigImportButton: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @State private var showImporter = false
  @State private var isReading = false
  @State private var document: SSHConfigDocument?
  @State private var errorKey: String?
  @State private var readingTask: Task<Void, Never>?
  var iconOnly = false

  var body: some View {
    Button {
      showImporter = true
    } label: {
      if isReading {
        ProgressView().controlSize(.small)
      } else if iconOnly {
        Image(systemName: "square.and.arrow.down")
          #if os(macOS)
            .frame(width: 26, height: 26)
          #else
            .frame(minWidth: 44, minHeight: 44)
          #endif
      } else {
        SymbolLabel(key: "sshConfig.import", symbol: "square.and.arrow.down")
      }
    }
    .disabled(workspace.library == nil || isReading)
    .accessibilityLabel(preferences.text("sshConfig.import"))
    .help(preferences.text("sshConfig.import"))
    .accessibilityIdentifier("importSSHConfig")
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
      read(result)
    }
    .sheet(item: $document) { document in
      SSHConfigImportSheet(document: document)
    }
    .alert(
      preferences.text("sshConfig.import"),
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
        errorKey = "sshConfig.error.read"
      }
      return
    }
    isReading = true
    readingTask = Task {
      defer { isReading = false }
      do {
        let document = try await Task.detached(priority: .userInitiated) {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
          guard properties.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
          guard (properties.fileSize ?? 0) <= SSHConfigParser.maximumBytes else {
            throw SSHConfigParser.ParseError.limit
          }
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          var bytes = Data()
          while bytes.count <= SSHConfigParser.maximumBytes {
            let chunk =
              try handle.read(upToCount: SSHConfigParser.maximumBytes + 1 - bytes.count)
              ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
          }
          guard bytes.count <= SSHConfigParser.maximumBytes else {
            throw SSHConfigParser.ParseError.limit
          }
          guard let source = String(data: bytes, encoding: .utf8) else {
            throw SSHConfigParser.ParseError.encoding
          }
          return SSHConfigDocument(name: url.lastPathComponent, source: source)
        }.value
        guard !Task.isCancelled else { return }
        self.document = document
      } catch {
        guard !Task.isCancelled else { return }
        errorKey = (error as? SSHConfigParser.ParseError)?.localizationKey ?? "sshConfig.error.read"
      }
    }
  }
}

private struct SSHConfigImportSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  let document: SSHConfigDocument
  @State private var defaultUsername = ""
  @State private var parsed: SSHConfigParseResult?
  @State private var selectedIDs: Set<String> = []
  @State private var parsing = false
  @State private var saving = false
  @State private var parseErrorKey: String?
  @State private var report: SSHConfigImportReport?
  @State private var savingTask: Task<Void, Never>?

  private var eligibleIDs: Set<String> {
    guard let library = workspace.library else { return [] }
    return Set(
      (parsed?.entries ?? []).filter {
        $0.canImport && !SSHConfigImporter.isDuplicate($0, in: library)
      }.map(\.id))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(verbatim: document.name).font(.headline)
          Copy("sshConfig.explanation").foregroundStyle(.secondary)
          Copy("sshConfig.credentialsDetail").foregroundStyle(.secondary)
        }
        if report == nil {
          Section {
            TextField(preferences.text("sshConfig.defaultUsername"), text: $defaultUsername)
              .autocorrectionDisabled()
              .accessibilityIdentifier("sshConfigDefaultUsername")
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
          } footer: {
            Copy("sshConfig.defaultUsernameDetail")
          }
        }
        if parsing { ProgressView(preferences.text("sshConfig.parsing")) }
        if let parseErrorKey {
          Copy(parseErrorKey).foregroundStyle(.red)
        }
        if let parsed {
          if !parsed.diagnostics.isEmpty {
            Section {
              ForEach(Array(parsed.diagnostics.enumerated()), id: \.offset) { _, issue in
                issueView(issue)
              }
            } header: {
              Copy("sshConfig.documentBlocked")
            }
          }
          if parsed.entries.isEmpty {
            Section { Copy("sshConfig.empty").foregroundStyle(.secondary) }
          } else {
            Section {
              if report == nil {
                Button(
                  preferences.text(
                    eligibleIDs.isSubset(of: selectedIDs)
                      ? "sshConfig.selectNone" : "sshConfig.selectAll")
                ) {
                  selectedIDs = eligibleIDs.isSubset(of: selectedIDs) ? [] : eligibleIDs
                }
                .disabled(eligibleIDs.isEmpty || parsing || saving)
              }
              ForEach(parsed.entries) { entry in
                entryView(entry)
              }
            } header: {
              Copy("sshConfig.preview")
            }
          }
        }
        if let report {
          Section {
            countRow("sshConfig.imported", report.importedCount)
            countRow("sshConfig.skipped", report.skippedCount)
            countRow("sshConfig.remaining", report.remainingCount)
            if let key = report.errorKey { Copy(key).foregroundStyle(.red) }
          } header: {
            Copy("sshConfig.result")
          }
          .accessibilityIdentifier("sshConfigImportResult")
        }
        if saving { ProgressView(preferences.text("host.saving")) }
      }
      .formStyle(.grouped)
      .disabled(saving)
      .navigationTitle(preferences.text("sshConfig.import"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(preferences.text(report == nil ? "action.cancel" : "action.done")) { dismiss() }
            .disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if report == nil {
            Button(preferences.text("sshConfig.saveSelected")) { save() }
              .disabled(
                parsing || saving || selectedIDs.intersection(eligibleIDs).isEmpty
                  || workspace.library == nil
              )
              .accessibilityIdentifier("sshConfigSaveSelected")
          }
        }
      }
    }
    .interactiveDismissDisabled(saving)
    .task(id: defaultUsername) { await parse() }
    .onDisappear { savingTask?.cancel() }
    #if os(macOS)
      .frame(width: 640, height: 700)
    #endif
  }

  private func entryView(_ entry: SSHConfigEntry) -> some View {
    let duplicate = workspace.library.map { SSHConfigImporter.isDuplicate(entry, in: $0) } ?? false
    return VStack(alignment: .leading, spacing: 6) {
      Toggle(
        isOn: Binding(
          get: { selectedIDs.contains(entry.id) },
          set: { selected in
            if selected { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) }
          })
      ) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: entry.alias).font(.headline)
          Text(verbatim: "\(entry.username)@\(entry.hostname):\(entry.port)")
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .disabled(!entry.canImport || duplicate || parsing || saving || report != nil)
      .accessibilityIdentifier("sshConfigEntry.\(entry.id)")
      if duplicate {
        Copy("sshConfig.duplicate").font(.caption).foregroundStyle(.secondary)
      }
      if entry.requiresPrivateKey {
        SymbolLabel(key: "sshConfig.identityFile", symbol: "key")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(entry.issues.prefix(16).enumerated()), id: \.offset) { _, issue in
        issueView(issue)
      }
    }
    .padding(.vertical, 4)
  }

  private func issueView(_ issue: SSHConfigIssue) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Copy(issue.key).font(.caption).foregroundStyle(.red)
      if let line = issue.line {
        HStack(spacing: 6) {
          Text(
            verbatim: String(
              format: preferences.text("sshConfig.line"), locale: preferences.language.locale,
              Int64(line)))
          if let directive = issue.directive { Text(verbatim: directive) }
        }
        .font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
  }

  private func countRow(_ key: String, _ count: Int) -> some View {
    LabeledContent(preferences.text(key)) { Text(count, format: .number) }
  }

  private func parse() async {
    guard report == nil else { return }
    parsing = true
    let previousEligible = eligibleIDs
    let source = document.source
    let username = defaultUsername
    do {
      let value = try await Task.detached(priority: .userInitiated) {
        try SSHConfigParser.parse(source, defaultUsername: username)
      }.value
      guard !Task.isCancelled else { return }
      parsed = value
      parseErrorKey = nil
      selectedIDs = selectedIDs.intersection(eligibleIDs)
        .union(eligibleIDs.subtracting(previousEligible))
    } catch {
      guard !Task.isCancelled else { return }
      parsed = nil
      selectedIDs = []
      parseErrorKey =
        (error as? SSHConfigParser.ParseError)?.localizationKey ?? "sshConfig.error.read"
    }
    parsing = false
  }

  private func save() {
    guard !saving, !parsing, let library = workspace.library, let parsed else { return }
    let selection = selectedIDs.intersection(eligibleIDs)
    guard !selection.isEmpty else { return }
    saving = true
    savingTask = Task {
      report = await SSHConfigImporter.save(parsed.entries, selectedIDs: selection, to: library)
      saving = false
    }
  }
}
