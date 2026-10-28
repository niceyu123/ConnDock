import SwiftUI
import UniformTypeIdentifiers

struct NewHostSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  @State private var displayName = ""
  @State private var hostname = ""
  @State private var username = ""
  @State private var port = "22"
  @State private var authentication: HostAuthMethod = .password
  @State private var groupID: UUID?
  @State private var favorite = false
  @State private var notes = ""
  @State private var tags = ""
  @State private var password = ""
  @State private var privateKey = ""
  @State private var keyName = ""
  @State private var passphrase = ""
  @State private var saveConfiguration = true
  @State private var rememberCredential = false
  @State private var isSaving = false
  @State private var showKeyImporter = false
  @State private var errorKey: String?
  private let savedID: UUID?
  private let revision: Int64?
  private let savedIdentity: ConnectionTarget?
  private let hasSavedCredential: Bool
  private let testOnly: Bool

  init(
    host: StoredHost? = nil, target: ConnectionTarget? = nil, requireCredential: Bool = false,
    testOnly: Bool = false, persistenceAvailable: Bool = true
  ) {
    savedID = host?.id
    revision = host?.syncRevision
    savedIdentity = host?.target
    hasSavedCredential = host?.credentialRef != nil && !requireCredential
    self.testOnly = testOnly
    let target = host?.target ?? target
    if let target {
      _displayName = State(initialValue: target.displayName)
      _hostname = State(initialValue: target.host)
      _username = State(initialValue: target.username)
      _port = State(initialValue: String(target.port))
      _authentication = State(initialValue: target.usesPrivateKey ? .ed25519 : .password)
    }
    _groupID = State(initialValue: host?.groupID)
    _favorite = State(initialValue: host?.favorite ?? false)
    _notes = State(initialValue: host?.notes ?? "")
    _saveConfiguration = State(initialValue: persistenceAvailable && (host != nil || target == nil))
    _rememberCredential = State(initialValue: host?.credentialRef != nil)
  }

  private var draft: HostDraft? {
    guard let port = UInt16(port), port > 0 else { return nil }
    var value = HostDraft(
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
      hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
      username: username.trimmingCharacters(in: .whitespacesAndNewlines), authMethod: authentication
    )
    guard !value.hostname.isEmpty, !value.username.isEmpty else { return nil }
    value.id = savedID
    value.revision = revision
    value.groupID = groupID
    value.favorite = favorite
    value.notes = notes
    value.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，"))
    return value
  }

  private var enteredCredential: SavedCredential? {
    switch authentication {
    case .password: password.isEmpty ? nil : .password(password)
    case .ed25519:
      privateKey.isEmpty
        ? nil : .ed25519(privateKey: privateKey, passphrase: passphrase.isEmpty ? nil : passphrase)
    }
  }
  private var canReuseCredential: Bool {
    guard hasSavedCredential, let savedIdentity, let draft else { return false }
    return draft.target.hasSameIdentity(as: savedIdentity)
  }
  private var canConnect: Bool {
    draft != nil && (enteredCredential != nil || canReuseCredential) && !isSaving
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(preferences.text("host.name"), text: $displayName).accessibilityIdentifier(
            "connectionName")
          TextField(preferences.text("host.address"), text: $hostname).autocorrectionDisabled()
            .accessibilityIdentifier("connectionHost")
          TextField(preferences.text("host.port"), text: $port).accessibilityIdentifier(
            "connectionPort")
          TextField(preferences.text("host.username"), text: $username).autocorrectionDisabled()
            .accessibilityIdentifier("connectionUsername")
        } header: {
          Copy("host.connection")
        }
        Section {
          Picker(preferences.text("host.authentication"), selection: $authentication) {
            ForEach(HostAuthMethod.allCases, id: \.self) { method in
              Copy(method.titleKey).tag(method)
            }
          }.accessibilityIdentifier("connectionAuthentication")
          if authentication == .password {
            SecureField(preferences.text("host.password"), text: $password).accessibilityIdentifier(
              "connectionPassword")
          } else {
            Button {
              showKeyImporter = true
            } label: {
              SymbolLabel(key: "ssh.key.import", symbol: "doc.badge.plus")
            }
            .accessibilityIdentifier("importPrivateKey")
            if !keyName.isEmpty { Text(verbatim: keyName).font(.caption).textSelection(.enabled) }
            SecureField(preferences.text("ssh.key.passphrase"), text: $passphrase)
          }
          if canReuseCredential {
            SymbolLabel(key: "host.savedCredentialAvailable", symbol: "key.fill").foregroundStyle(
              .secondary)
          }
          if hasSavedCredential && !canReuseCredential {
            Copy("host.identityChanged").foregroundStyle(.secondary)
          }
        } header: {
          Copy("host.authentication")
        }
        Section {
          Toggle(preferences.text("host.saveConfiguration"), isOn: $saveConfiguration)
            .disabled(workspace.library == nil).accessibilityIdentifier("saveHostToggle")
          if saveConfiguration {
            Toggle(preferences.text("host.rememberCredential"), isOn: $rememberCredential)
              .accessibilityIdentifier("rememberCredentialToggle")
            Picker(preferences.text("hosts.groups"), selection: $groupID) {
              Copy("hosts.ungrouped").tag(UUID?.none)
              ForEach(workspace.library?.groups ?? []) { group in
                Text(verbatim: group.name).tag(Optional(group.id))
              }
            }.accessibilityIdentifier("hostGroupPicker")
            Toggle(preferences.text("hosts.favorite"), isOn: $favorite)
            TextField(preferences.text("host.tags"), text: $tags)
              .accessibilityIdentifier("hostTags")
            TextField(preferences.text("host.notes"), text: $notes, axis: .vertical).lineLimit(
              2...4)
          }
        } footer: {
          Copy(saveConfiguration ? "host.storageDetail" : "ssh.credentials.memoryOnly")
        }
        if let errorKey {
          Copy(errorKey).foregroundStyle(.red).accessibilityIdentifier("connectionError")
        }
        if isSaving { ProgressView(preferences.text("host.saving")) }
      }
      .disabled(isSaving)
      .formStyle(.grouped)
      .navigationTitle(
        preferences.text(
          testOnly ? "hosts.testConnection" : savedID == nil ? "action.newHost" : "host.edit")
      )
      #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
              cancelButton.keyboardShortcut(.cancelAction)
              Spacer()
              saveButton
              connectButton.keyboardShortcut(.defaultAction)
            }.buttonStyle(.bordered).padding(16)
          }.background(.bar)
        }
      #else
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { cancelButton }
          ToolbarItemGroup(placement: .confirmationAction) {
            saveButton
            connectButton
          }
        }
      #endif
      .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
        importKey(result)
      }
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
    }
    .interactiveDismissDisabled(isSaving)
    .task {
      if let savedID { tags = workspace.library?.tags(for: savedID).joined(separator: ", ") ?? "" }
    }
    #if os(macOS)
      .frame(width: 540, height: 680)
    #endif
    .onDisappear {
      password = ""
      privateKey = ""
      passphrase = ""
    }
  }

  private var cancelButton: some View {
    Button(preferences.text("action.cancel")) { dismiss() }.disabled(isSaving)
  }

  private var saveButton: some View {
    Button(preferences.text("action.save")) { Task { await perform(connect: false) } }
      .disabled(draft == nil || !saveConfiguration || isSaving)
      .accessibilityIdentifier("connectionSave")
  }

  private var connectButton: some View {
    Button(preferences.text(testOnly ? "hosts.testConnection" : "action.connect")) {
      Task { await perform(connect: true) }
    }
    .disabled(!canConnect).accessibilityIdentifier("connectionConnect")
  }

  private func perform(connect: Bool) async {
    guard let draft else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      var credential = enteredCredential
      if connect && credential == nil, canReuseCredential, let savedID,
        let library = workspace.library, let host = library.host(savedID)
      {
        guard host.target.hasSameIdentity(as: draft.target), host.syncRevision == revision else {
          throw HostLibraryError.conflict
        }
        credential = try await library.credential(for: host)
      }
      if connect && credential == nil { throw HostLibraryError.credential }
      var hostID: UUID?
      if saveConfiguration {
        guard let library = workspace.library else { throw HostLibraryError.unavailable }
        let saved = try await library.saveHost(
          draft, credential: enteredCredential, rememberCredential: rememberCredential)
        hostID = saved.id
        workspace.selectedHostID = saved.id
      } else if let savedID, savedIdentity?.hasSameIdentity(as: draft.target) == true {
        hostID = savedID
      }
      if connect, let credential {
        workspace.connect(
          target: draft.target, authentication: credential.request, sourceHostID: hostID,
          testOnly: testOnly)
      }
      password = ""
      privateKey = ""
      passphrase = ""
      dismiss()
    } catch {
      errorKey = (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
    }
  }

  private func importKey(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 128 * 1024 + 1) ?? Data()
      guard data.count <= 128 * 1024, let content = String(data: data, encoding: .utf8),
        content.contains("-----BEGIN OPENSSH PRIVATE KEY-----")
      else {
        errorKey = "ssh.error.invalidPrivateKey"
        return
      }
      privateKey = content
      keyName = url.lastPathComponent
      errorKey = nil
    } catch { errorKey = "ssh.error.keyImport" }
  }
}

struct HostKeySheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  let challenge: HostKeyChallenge

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent(preferences.text("host.address")) {
            Text(verbatim: "\(challenge.target.host):\(challenge.target.port)").textSelection(
              .enabled)
          }
          LabeledContent(preferences.text("ssh.trust.algorithm")) {
            Text(verbatim: challenge.algorithm)
          }
          Text(verbatim: challenge.fingerprint)
            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .accessibilityIdentifier("hostKeyFingerprint")
        } header: {
          Copy("ssh.trust.fingerprint")
        }
        Section { Copy("ssh.trust.explanation") }
      }
      .formStyle(.grouped)
      .navigationTitle(preferences.text("ssh.trust.title"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(preferences.text("action.cancel")) {
            workspace.resolveTrust(challenge: challenge, accept: false)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(preferences.text("ssh.trust.accept")) {
            workspace.resolveTrust(challenge: challenge, accept: true)
          }
          .accessibilityIdentifier("trustHostKey")
        }
      }
    }
    .interactiveDismissDisabled()
    #if os(macOS)
      .frame(width: 600, height: 400)
    #endif
  }
}
