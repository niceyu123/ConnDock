import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct SaveDownloadedFile: View {
  @Environment(AppPreferences.self) private var preferences
  let url: URL
  @State private var exporting = false
  @State private var errorKey: String?

  var body: some View {
    Button(preferences.text("sftp.saveLocal")) {
      #if os(macOS)
        Task { await exportOnMac() }
      #else
        exporting = true
      #endif
    }
    .disabled(exporting)
    .accessibilityIdentifier("sftp.saveLocal")
    #if os(iOS)
      .sheet(isPresented: $exporting) { DocumentExportPicker(url: url) { exporting = false } }
    #endif
    .alert(
      preferences.text("common.error"),
      isPresented: Binding(get: { errorKey != nil }, set: { if !$0 { errorKey = nil } })
    ) {
      Button(preferences.text("action.done")) { errorKey = nil }
    } message: {
      Copy(errorKey ?? "sftp.error.export")
    }
  }

  #if os(macOS)
    @MainActor private func exportOnMac() async {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = url.lastPathComponent
      panel.canCreateDirectories = true
      guard await panel.begin() == .OK, let destination = panel.url else { return }
      exporting = true
      do { try await FileExportIO.copy(source: url, destination: destination) } catch {
        errorKey = "sftp.error.export"
      }
      exporting = false
    }
  #endif
}

#if os(macOS)
  private enum FileExportIO {
    static func copy(source: URL, destination: URL) async throws {
      try await Task.detached {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let staging = try manager.url(
          for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
          create: true)
        defer { try? manager.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try manager.copyItem(at: source, to: copy)
        if manager.fileExists(atPath: destination.path) {
          _ = try manager.replaceItemAt(destination, withItemAt: copy)
        } else {
          try manager.moveItem(at: copy, to: destination)
        }
      }.value
    }
  }
#else
  private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.delegate = context.coordinator
      return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
      let completed: () -> Void
      init(completed: @escaping () -> Void) { self.completed = completed }
      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completed() }
      func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
      ) { completed() }
    }
  }
#endif
