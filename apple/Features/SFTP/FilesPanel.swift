import SSHCoreBridge
import SwiftUI
import UniformTypeIdentifiers

struct FilesPanel: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.colorScheme) private var scheme
  @State private var selected = "files"

  private var isExpanded: Bool {
    #if os(macOS)
      preferences.filesVisible
    #else
      true
    #endif
  }

  var body: some View {
    let palette = WorkspacePalette(scheme: scheme)
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        #if os(macOS)
          IconButton(
            key: isExpanded ? "layout.hideFiles" : "layout.showFiles",
            symbol: isExpanded ? "chevron.down" : "chevron.right"
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              preferences.filesVisible.toggle()
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sftp.togglePanel")
        #endif
        ForEach(["files", "transfers", "commands"], id: \.self) { tab in
          Button {
            select(tab)
          } label: {
            HStack(spacing: 5) {
              SymbolLabel(
                key: tab == "commands" ? "commands.title" : "sftp.\(tab)",
                symbol: tab == "files"
                  ? "folder" : tab == "transfers" ? "arrow.up.arrow.down" : "terminal")
              if tab == "transfers", let model = workspace.selectedSession?.files {
                let count = model.transfers.filter { $0.status.isActive || $0.status == .queued }
                  .count
                if count > 0 { Text(count, format: .number).font(.caption.monospacedDigit()) }
              }
            }
            .font(.system(size: 12, weight: selected == tab && isExpanded ? .semibold : .regular))
            .foregroundStyle(selected == tab && isExpanded ? palette.accent : .secondary)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sftp.tab.\(tab)")
          .accessibilityAddTraits(selected == tab && isExpanded ? .isSelected : [])
        }
        Spacer(minLength: 0)
        #if os(macOS)
          Button {
            withAnimation(.easeInOut(duration: 0.2)) {
              preferences.filesVisible.toggle()
            }
          } label: {
            HStack(spacing: 3) {
              Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 9))
              Text(preferences.text(isExpanded ? "layout.collapsePanel" : "layout.expandPanel"))
                .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sftp.expandCollapseText")
        #endif
      }
      .padding(.horizontal, 10).frame(height: 36)
      if isExpanded {
        Divider()
        if selected == "commands" {
          CommandsPanel()
        } else if let session = workspace.selectedSession, let model = session.files {
          if selected == "files" {
            RemoteFileBrowser(model: model, target: session.target).id(session.id)
            if let transfer = model.transfers.first(where: {
              $0.status.isActive || $0.status == .queued
            })
              ?? model.transfers.last
            {
              Divider()
              VStack(spacing: 6) {
                HStack {
                  Button(preferences.text("sftp.showTransfers")) { selected = "transfers" }
                    .accessibilityIdentifier("sftp.showTransfers")
                  Spacer()
                  if !model.transfers.contains(where: { $0.status.isActive || $0.status == .queued }
                  ) {
                    IconButton(key: "sftp.clearFinished", symbol: "xmark") {
                      model.clearFinishedTransfers()
                    }
                  }
                }
                .font(.caption).buttonStyle(.plain)
                TransferRow(model: model, transfer: transfer).id(transfer.id)
              }
              .padding(.horizontal, 16).padding(.vertical, 8)
            }
          } else {
            TransferList(model: model)
          }
        } else {
          EmptyPanel(
            symbol: "folder.badge.questionmark", title: "sftp.empty", detail: "sftp.emptyDetail",
            compact: true)
        }
      }
    }
    .background(palette.panel)
    .onChange(of: workspace.selectedSession?.files?.transfers.count) { oldCount, newCount in
      #if os(macOS)
        if newCount ?? 0 > oldCount ?? 0 {
          preferences.filesHeight = max(preferences.filesHeight, 320)
        }
      #endif
    }
    .onChange(of: workspace.selectedSession?.files?.showUploadImporter) { _, value in
      if value == true {
        selected = "files"
        preferences.filesVisible = true
      }
    }
  }

  private func select(_ tab: String) {
    #if os(macOS)
      withAnimation(.easeInOut(duration: 0.2)) {
        preferences.filesVisible = true
      }
    #endif
    selected = tab
  }
}

private struct RemoteFileBrowser: View {
  @Environment(AppPreferences.self) private var preferences
  @Bindable var model: RemoteFilesModel
  let target: ConnectionTarget
  @State private var showNameEditor = false
  @State private var editingEntry: RemoteFileEntry?
  @State private var deletingEntry: RemoteFileEntry?
  @State private var uploadCollision: URL?
  @State private var editingDirectory: String?
  @State private var deletingDirectory: String?
  @State private var uploadDestination: UploadDestination?
  @State private var pendingUploads: [FileUploadSource] = []
  @State private var isDropTargeted = false

  var body: some View {
    let destination = model.uploadDestination
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        IconButton(key: "sftp.parent", symbol: "arrow.up") {
          model.browse(RemotePaths.parent(model.path ?? "/"))
        }
        .disabled(model.path == nil || model.path == "/" || model.isLoading)
        IconButton(key: "sftp.home", symbol: "house") { model.browse(".") }
        Text(verbatim: model.path ?? preferences.text("sftp.noPath"))
          .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled).accessibilityIdentifier("sftp.currentPath")
          .accessibilityLabel(model.path ?? preferences.text("sftp.noPath"))
          .accessibilityValue(model.path ?? "")
        Spacer(minLength: 0)
        bookmarkControls
        IconButton(key: "sftp.refresh", symbol: "arrow.clockwise") { model.browse() }
          .accessibilityIdentifier("sftp.refresh")
      }
      .padding(.horizontal, 12).padding(.vertical, 4)
      .disabled(!model.isConnected)
      HStack(spacing: 14) {
        Button {
          editingEntry = nil
          editingDirectory = model.path
          showNameEditor = true
        } label: {
          SymbolLabel(key: "sftp.newDirectory", symbol: "folder.badge.plus")
        }
        .accessibilityIdentifier("sftp.newDirectory")
        Button {
          model.showUploadImporter = true
          uploadDestination = model.uploadDestination
        } label: {
          SymbolLabel(key: "action.upload", symbol: "square.and.arrow.up")
        }
        .accessibilityIdentifier("sftp.upload")
        Button {
          model.download()
        } label: {
          SymbolLabel(key: "action.download", symbol: "square.and.arrow.down")
        }
        .disabled(!model.canDownloadSelection).accessibilityIdentifier("sftp.download")
        Spacer(minLength: 0)
        if model.isLoading { ProgressView().controlSize(.small) }
      }
      .font(.caption).buttonStyle(.borderless)
      .padding(.horizontal, 16).padding(.vertical, 6)
      .disabled(!model.isConnected || model.isLoading || model.path == nil)
      Divider()
      #if os(macOS)
        if model.isConnected {
          HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc").accessibilityHidden(true)
            Copy("sftp.dropHint")
          }
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
      #endif
      if let error = model.errorKey {
        HStack {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Copy(error).font(.caption).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button(preferences.text("action.retry")) { model.browse() }
        }
        .padding(12).accessibilityIdentifier("sftp.error")
      }
      if !model.isConnected {
        EmptyPanel(
          symbol: "network.slash", title: "ssh.state.disconnected", detail: "sftp.emptyDetail",
          compact: true)
      } else if model.isLoading && model.entries.isEmpty {
        ProgressView(preferences.text("sftp.loading")).frame(
          maxWidth: .infinity, maxHeight: .infinity)
      } else if model.entries.isEmpty {
        EmptyPanel(
          symbol: "folder", title: "sftp.emptyDirectory", detail: "sftp.emptyDirectoryDetail",
          compact: true)
      } else {
        List {
          ForEach(model.entries, id: \.name) { entry in
            fileRow(entry)
              .listRowBackground(
                model.selectedName == entry.name ? Color.primary.opacity(0.07) : .clear)
          }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .disabled(model.isLoading)
        .accessibilityIdentifier("sftp.directoryList")
      }
    }
    .contentShape(Rectangle())
    .dropDestination(for: URL.self) { urls, _ in
      guard let destination, pendingUploads.isEmpty, !urls.isEmpty else { return false }
      return acceptUploads(urls, to: destination)
    } isTargeted: {
      isDropTargeted = $0
    }
    .overlay {
      if isDropTargeted, let destination {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.accentColor.opacity(0.12))
          .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
          }
          .overlay {
            VStack(spacing: 6) {
              SymbolLabel(key: "sftp.dropUpload", symbol: "square.and.arrow.up")
                .font(.headline)
              Text(verbatim: destination.path).font(.caption.monospaced()).lineLimit(2)
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
          }
          .allowsHitTesting(false)
      }
    }
    .task(id: model.isConnected) { if model.isConnected { model.browse() } }
    .onDisappear {
      model.suspendBrowser()
      pendingUploads = []
      uploadCollision = nil
    }
    .onChange(of: uploadCollision) { _, collision in
      if collision == nil { pendingUploads = [] }
    }
    .fileImporter(
      isPresented: $model.showUploadImporter, allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let uploadDestination { _ = acceptUploads(urls, to: uploadDestination) }
      case .failure: model.errorKey = "sftp.error.localFile"
      }
    }
    .sheet(isPresented: $showNameEditor) {
      FileNameEditor(
        titleKey: editingEntry == nil ? "sftp.newDirectory" : "sftp.rename",
        initialName: editingEntry?.name ?? ""
      ) { name in
        let entry = editingEntry
        let directory = editingDirectory
        showNameEditor = false
        Task {
          if let entry {
            await model.rename(entry, to: name, in: directory)
          } else {
            await model.createDirectory(name: name, in: directory)
          }
        }
      }
    }
    .confirmationDialog(
      preferences.text("sftp.deleteTitle"),
      isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }),
      titleVisibility: .visible
    ) {
      if let entry = deletingEntry {
        let directory = deletingDirectory
        Button(preferences.text("action.delete"), role: .destructive) {
          Task { await model.remove(entry, in: directory) }
          deletingEntry = nil
        }
      }
    } message: {
      if let entry = deletingEntry {
        Text(
          verbatim: (try? RemotePaths.child(deletingDirectory ?? ".", name: entry.name))
            ?? entry.name)
      }
      Copy("sftp.deleteDetail")
    }
    .confirmationDialog(
      preferences.text("sftp.overwriteTitle"),
      isPresented: Binding(
        get: { uploadCollision != nil }, set: { if !$0 { uploadCollision = nil } }),
      titleVisibility: .visible
    ) {
      if uploadCollision != nil {
        Button(preferences.text("sftp.overwrite"), role: .destructive) {
          continueUploads(overwrite: true)
        }
        Button(preferences.text("action.cancel"), role: .cancel) { pendingUploads = [] }
      }
    } message: {
      Text(
        verbatim: pendingUploads.filter { source in
          model.entries.contains { $0.name == source.url.lastPathComponent }
        }.map { $0.url.lastPathComponent }.joined(separator: "\n"))
      Copy("sftp.overwriteDetail")
    }
  }

  private func acceptUploads(_ urls: [URL], to destination: UploadDestination) -> Bool {
    guard model.isCurrentUploadDestination(destination) else {
      model.errorKey = "sftp.error.staleSelection"
      return false
    }
    guard urls.count <= 50, model.transfers.count + urls.count <= 50 else {
      model.errorKey = "sftp.error.queueFull"
      return false
    }
    do {
      // Validate the whole selection before queueing any writes.
      pendingUploads = try urls.map { try FileUploadSource(url: $0) }
    } catch {
      model.errorKey = "sftp.error.uploadFilesOnly"
      return false
    }
    uploadDestination = destination
    continueUploads()
    return true
  }

  private func continueUploads(overwrite: Bool = false) {
    guard let destination = uploadDestination else {
      pendingUploads = []
      return
    }
    uploadCollision = nil
    if !overwrite,
      let collision = pendingUploads.first(where: { source in
        model.entries.contains { $0.name == source.url.lastPathComponent }
      })
    {
      uploadCollision = collision.url
      return
    }
    while let source = pendingUploads.first {
      guard model.isCurrentUploadDestination(destination) else {
        model.errorKey = "sftp.error.staleSelection"
        pendingUploads = []
        return
      }
      let replace = overwrite && model.entries.contains { $0.name == source.url.lastPathComponent }
      guard model.upload(source, to: destination, overwrite: replace) else {
        pendingUploads = []
        return
      }
      pendingUploads.removeFirst()
    }
  }

  private var bookmarkControls: some View {
    let store = preferences.remoteBookmarks
    let saved = store.items(for: target)
    let currentSaved = model.path.map { store.contains($0, for: target) } ?? false
    return HStack(spacing: 6) {
      IconButton(
        key: currentSaved ? "sftp.removeBookmark" : "sftp.addBookmark",
        symbol: currentSaved ? "star.fill" : "star"
      ) {
        if let path = model.path { toggleBookmark(path) }
      }
      .disabled(model.path == nil || model.isLoading)
      .accessibilityIdentifier("sftp.bookmarkCurrent")
      Menu {
        if saved.isEmpty { Text(verbatim: preferences.text("sftp.noBookmarks")) }
        ForEach(saved) { bookmark in
          Button {
            model.browse(bookmark.path, selecting: bookmark.selectedName)
          } label: {
            Text(verbatim: "\(bookmark.title) — \(bookmark.path)")
          }
        }
        if !saved.isEmpty {
          Divider()
          Menu(preferences.text("sftp.removeBookmark")) {
            ForEach(saved) { bookmark in
              Button(role: .destructive) {
                do { try store.remove(bookmark) } catch { model.errorKey = "sftp.bookmarkError" }
              } label: {
                Text(verbatim: "\(bookmark.title) — \(bookmark.path)")
              }
            }
          }
        }
      } label: {
        SymbolLabel(key: "sftp.bookmarks", symbol: "bookmark")
      }
      .menuStyle(.borderlessButton).fixedSize()
      .disabled(model.isLoading)
      .accessibilityIdentifier("sftp.bookmarks")
    }
  }

  private func toggleBookmark(_ path: String, selectedName: String? = nil) {
    do {
      try preferences.remoteBookmarks.toggle(path, selectedName: selectedName, for: target)
    } catch { model.errorKey = "sftp.bookmarkError" }
  }

  private func fileRow(_ entry: RemoteFileEntry) -> some View {
    let directory = model.path
    return HStack(spacing: 10) {
      Image(
        systemName: entry.kind == .directory
          ? "folder.fill" : entry.kind == .symlink ? "link" : "doc"
      )
      .foregroundStyle(entry.kind == .directory ? .blue : .secondary).accessibilityHidden(true)
      Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      if let size = entry.size, entry.kind != .directory {
        Text(
          verbatim: Int64(clamping: size).formatted(
            .byteCount(style: .file).locale(preferences.language.locale))
        )
        .foregroundStyle(.secondary).font(.caption.monospacedDigit())
      }
      #if os(macOS)
        if let modified = entry.modifiedSeconds {
          Text(
            Date(timeIntervalSince1970: Double(modified)),
            format: .dateTime.month(.abbreviated).day().hour().minute().locale(
              preferences.language.locale)
          )
          .font(.caption).foregroundStyle(.secondary).frame(width: 115, alignment: .trailing)
        }
        if let permissions = entry.permissions {
          Text(verbatim: String(format: "%03o", permissions & 0o7777)).font(.caption.monospaced())
            .foregroundStyle(.secondary).frame(width: 36)
        }
      #endif
    }
    .font(.callout).padding(.vertical, 4).contentShape(Rectangle())
    .onTapGesture(count: 2) { model.open(entry) }
    .onTapGesture {
      model.selectedName = entry.name
      #if os(iOS)
        if entry.kind == .directory { model.open(entry) }
      #endif
    }
    .contextMenu {
      if let directory {
        let bookmarkPath =
          entry.kind == .directory
          ? try? RemotePaths.child(directory, name: entry.name) : directory
        let selectedName = entry.kind == .directory ? nil : entry.name
        if let bookmarkPath {
          let saved = preferences.remoteBookmarks.contains(
            bookmarkPath, selectedName: selectedName, for: target)
          Button(preferences.text(saved ? "sftp.removeBookmark" : "sftp.addBookmark")) {
            toggleBookmark(bookmarkPath, selectedName: selectedName)
          }
          Divider()
        }
      }
      if entry.kind == .directory || entry.kind == .symlink {
        Button(preferences.text("sftp.openDirectory")) { model.open(entry) }
      }
      if entry.kind == .regular || entry.kind == .symlink {
        Button(preferences.text("action.download")) { model.download(entry, from: directory) }
      }
      Button(preferences.text("sftp.rename")) {
        editingEntry = entry
        editingDirectory = directory
        showNameEditor = true
      }
      Button(preferences.text("action.delete"), role: .destructive) {
        deletingEntry = entry
        deletingDirectory = directory
      }
    }
    .accessibilityIdentifier("sftp.entry.\(entry.name)")
  }
}

private struct FileNameEditor: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(\.dismiss) private var dismiss
  let titleKey: String
  let initialName: String
  let submit: (String) -> Void
  @State private var name = ""
  private var valid: Bool { (try? RemotePaths.child("/", name: name)) != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Copy(titleKey).font(.headline)
      TextField(preferences.text("sftp.name"), text: $name).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("sftp.nameField")
      HStack {
        Button(preferences.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(preferences.text("action.save")) { submit(name) }.disabled(!valid).keyboardShortcut(
          .defaultAction)
      }
    }
    .padding(24).frame(idealWidth: 400).onAppear { name = initialName }
    .preferredColorScheme(preferences.appearance.colorScheme)
    .presentationDetents([.medium])
  }
}

private struct TransferList: View {
  @Environment(AppPreferences.self) private var preferences
  @Bindable var model: RemoteFilesModel
  var body: some View {
    VStack(spacing: 0) {
      if model.transfers.isEmpty {
        EmptyPanel(
          symbol: "arrow.up.arrow.down.circle", title: "sftp.noTransfers",
          detail: "sftp.transferDetail", compact: true)
      } else {
        HStack {
          Copy("sftp.transferLimit").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(preferences.text("sftp.clearFinished")) { model.clearFinishedTransfers() }.font(
            .caption)
        }.padding(.horizontal, 16).padding(.vertical, 8)
        List(model.transfers) { transfer in
          TransferRow(model: model, transfer: transfer).padding(.vertical, 5)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
      }
    }
  }
}

private struct TransferRow: View {
  @Environment(AppPreferences.self) private var preferences
  let model: RemoteFilesModel
  let transfer: FileTransfer
  @State private var confirmOverwrite = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: transfer.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
          .accessibilityLabel(
            preferences.text(transfer.direction == .upload ? "action.upload" : "action.download"))
        Text(verbatim: transfer.name).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        Copy(transfer.status.key).foregroundStyle(.secondary)
          .accessibilityIdentifier("sftp.transfer.\(transfer.status.rawValue)")
        if transfer.status.isActive || transfer.status == .queued {
          IconButton(key: "action.cancel", symbol: "xmark.circle") { model.cancel(transfer) }
            .disabled(transfer.status == .cancelling || transfer.status == .finishing)
        } else if transfer.status == .failed || transfer.status == .cancelled {
          Button(preferences.text(transfer.canOverwrite ? "sftp.overwriteRetry" : "action.retry")) {
            if transfer.canOverwrite { confirmOverwrite = true } else { model.retry(transfer) }
          }.disabled(!model.isConnected)
        } else if let url = transfer.downloadedURL {
          SaveDownloadedFile(url: url)
        }
      }
      .font(.caption).buttonStyle(.borderless)
      if let progress = transfer.fractionCompleted {
        ProgressView(value: progress).progressViewStyle(.linear)
          .accessibilityLabel(transfer.name)
          .accessibilityIdentifier("sftp.transferProgress")
      } else if transfer.status.isActive || transfer.status == .queued {
        ProgressView().progressViewStyle(.linear)
          .accessibilityLabel(preferences.text(transfer.status.key))
      }
      HStack {
        Text(verbatim: byteCount(transfer.bytesTransferred))
        if let total = transfer.totalBytes {
          Text(verbatim: "/")
          Text(verbatim: byteCount(total))
        }
        Spacer()
        if let fraction = transfer.fractionCompleted {
          Text(fraction, format: .percent.precision(.fractionLength(0)))
        }
      }
      .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      if let error = transfer.errorKey {
        Copy(error).font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      preferences.text("sftp.overwriteTitle"), isPresented: $confirmOverwrite,
      titleVisibility: .visible
    ) {
      Button(preferences.text("sftp.overwrite"), role: .destructive) {
        model.retry(transfer, overwrite: true)
      }
    } message: {
      Text(verbatim: transfer.remotePath)
      Copy("sftp.overwriteDetail")
    }
  }

  private func byteCount(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(preferences.language.locale))
  }
}
