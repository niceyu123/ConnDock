import SwiftTerm
import SwiftUI

struct TerminalFindBar: View {
  @Environment(AppPreferences.self) private var preferences
  let terminal: TerminalView
  let request: UUID
  let close: () -> Void
  @State private var query = ""
  @State private var searchedQuery: String?
  @State private var hasMatch = false
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      TextField(preferences.text("terminal.find.title"), text: $query)
        .textFieldStyle(.roundedBorder).autocorrectionDisabled().submitLabel(.search)
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .focused($isFocused)
        .accessibilityIdentifier("terminalFindText")
        .onSubmit { find(forward: true) }
        .onKeyPress(.escape) {
          close()
          return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
          guard press.modifiers.contains(.shift) else { return .ignored }
          find(forward: false)
          return .handled
        }
      if !query.isEmpty, searchedQuery == query {
        Copy(hasMatch ? "terminal.find.match" : "terminal.find.noMatch")
          .font(.caption2).foregroundStyle(.secondary)
          .accessibilityIdentifier("terminalFindStatus")
      }
      IconButton(key: "terminal.find.previous", symbol: "chevron.up") { find(forward: false) }
        .disabled(query.isEmpty).accessibilityIdentifier("terminalFindPrevious")
      IconButton(key: "terminal.find.next", symbol: "chevron.down") { find(forward: true) }
        .disabled(query.isEmpty).accessibilityIdentifier("terminalFindNext")
      IconButton(key: "terminal.find.close", symbol: "xmark", action: close)
        .accessibilityIdentifier("terminalFindClose")
    }
    .font(.callout).buttonStyle(.plain)
    .padding(.horizontal, 8).padding(.vertical, 4)
    .task(id: request) {
      await Task.yield()
      if !Task.isCancelled { isFocused = true }
    }
    .task(id: query) {
      // Searching runs against the native view's bounded scrollback on the main actor.
      if query.isEmpty {
        clearSearch()
      } else {
        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled, searchedQuery != query else { return }
        find(forward: true)
      }
    }
    .onDisappear { clearSearch() }
  }

  private func find(forward: Bool) {
    guard !query.isEmpty else { return }
    hasMatch = forward ? terminal.findNext(query) : terminal.findPrevious(query)
    searchedQuery = query
  }

  private func clearSearch() {
    if searchedQuery != nil { terminal.clearSearch() }
    searchedQuery = nil
  }
}
