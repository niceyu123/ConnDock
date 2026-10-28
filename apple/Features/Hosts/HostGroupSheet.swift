import SwiftUI

struct HostGroupSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var errorKey: String?
  private let id: UUID?
  private let revision: Int64?

  init(group: StoredHostGroup? = nil) {
    id = group?.id
    revision = group?.syncRevision
    _name = State(initialValue: group?.name ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(preferences.text("group.name"), text: $name).accessibilityIdentifier("groupName")
        if let errorKey { Copy(errorKey).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle(preferences.text(id == nil ? "group.new" : "group.rename"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(preferences.text("action.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(preferences.text("action.save")) {
            do {
              guard let library = workspace.library else { throw HostLibraryError.unavailable }
              if let id, let revision {
                try library.renameGroup(id, name: name, expectedRevision: revision)
              } else {
                try library.createGroup(name: name)
              }
              dismiss()
            } catch {
              errorKey =
                (error as? HostLibraryError)?.localizationKey ?? "storage.error.unavailable"
            }
          }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("groupSave")
        }
      }
    }
    #if os(macOS)
      .frame(width: 420, height: 240)
    #endif
  }
}
