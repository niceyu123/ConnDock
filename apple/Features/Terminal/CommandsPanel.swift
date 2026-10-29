import SwiftUI

private struct CommandExecution: Identifiable {
  let id = UUID()
  let command: SavedCommand
  let sessionID: UUID
  let target: ConnectionTarget
}

struct CommandsPanel: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @State private var editing: SavedCommand?
  @State private var execution: CommandExecution?
  private var library: CommandLibrary { workspace.commandLibrary }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Copy("commands.savedLocally").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          editing = SavedCommand(name: "", command: "")
        } label: {
          SymbolLabel(key: "commands.add", symbol: "plus")
        }
        .disabled(!library.isLoaded || library.isBusy)
        .accessibilityIdentifier("commands.add")
      }
      .padding(.horizontal, 16).padding(.vertical, 8)
      if let error = library.errorKey {
        HStack {
          Copy(error).foregroundStyle(.orange)
          if !library.isLoaded {
            Button(preferences.text("action.retry")) { Task { await library.load() } }
              .disabled(library.isBusy)
          }
        }.font(.caption).padding(8)
      }
      if library.isBusy && !library.isLoaded {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if library.isLoaded && library.commands.isEmpty {
        EmptyPanel(
          symbol: "text.badge.plus", title: "commands.empty", detail: "commands.emptyDetail",
          compact: true)
      } else {
        List(library.commands) { command in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(verbatim: command.name).font(.callout.weight(.medium))
              Text(verbatim: command.command).font(.caption.monospaced())
                .lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(key: "commands.edit", symbol: "pencil") { editing = command }
            IconButton(key: "commands.run", symbol: "play.fill") {
              guard let session = workspace.selectedSession, session.canSendInput else { return }
              execution = CommandExecution(
                command: command, sessionID: session.id, target: session.target)
            }
            .disabled(workspace.selectedSession?.canSendInput != true)
            IconButton(key: "action.delete", symbol: "trash") {
              Task { await library.remove(command) }
            }
          }
          .buttonStyle(.borderless).padding(.vertical, 4)
          .disabled(library.isBusy)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
      }
    }
    .task { await library.load() }
    .sheet(item: $editing) { CommandEditor(initial: $0, library: library) }
    .sheet(item: $execution) { CommandExecutionSheet(request: $0) }
  }
}

private struct CommandEditor: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(\.dismiss) private var dismiss
  let initial: SavedCommand
  let library: CommandLibrary
  @State private var name = ""
  @State private var command = ""
  private var draft: SavedCommand { SavedCommand(id: initial.id, name: name, command: command) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Copy(initial.name.isEmpty ? "commands.add" : "commands.edit").font(.headline)
      TextField(preferences.text("commands.name"), text: $name).textFieldStyle(.roundedBorder)
      Copy("commands.content").font(.subheadline)
      TextEditor(text: $command).font(.body.monospaced()).frame(minHeight: 130)
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)) }
        .accessibilityLabel(preferences.text("commands.content"))
      Copy("commands.storageDetail").font(.caption).foregroundStyle(.secondary)
      if let error = library.errorKey { Copy(error).font(.caption).foregroundStyle(.orange) }
      HStack {
        Button(preferences.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(preferences.text("action.save")) {
          let value = draft
          Task { if await library.save(value) { dismiss() } }
        }
        .keyboardShortcut(.defaultAction).disabled(!draft.isValid || library.isBusy)
      }
    }
    .padding(24).frame(idealWidth: 480)
    .onAppear {
      name = initial.name
      command = initial.command
    }
    .interactiveDismissDisabled(library.isBusy)
  }
}

private struct CommandExecutionSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  let request: CommandExecution

  private var session: TerminalSession? {
    guard let session = workspace.selectedSession,
      session.id == request.sessionID, session.target == request.target, session.canSendInput
    else { return nil }
    return session
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Copy("commands.confirmRun").font(.headline)
      Text(verbatim: "\(request.target.username)@\(request.target.host):\(request.target.port)")
        .font(.callout.monospaced()).textSelection(.enabled)
      ScrollView {
        Text(verbatim: request.command.command).font(.body.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }
      .frame(minHeight: 100, maxHeight: 280)
      Copy(session == nil ? "commands.targetChanged" : "commands.runDetail")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(preferences.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(preferences.text("commands.run")) {
          guard let session else { return }
          session.send(Array((request.command.command + "\r").utf8))
          dismiss()
        }.disabled(session == nil)
      }
    }
    .padding(24).frame(idealWidth: 520)
  }
}
