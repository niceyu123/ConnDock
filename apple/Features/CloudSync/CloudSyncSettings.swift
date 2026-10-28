import SwiftUI

struct CloudSyncSettings: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  @State private var confirmEnable = false
  @State private var confirmDelete = false

  var body: some View {
    if let service = workspace.cloudSync {
      Section {
        Toggle(
          preferences.text("cloud.enable"),
          isOn: Binding(
            get: { service.isEnabled },
            set: { enabled in if enabled { confirmEnable = true } else { service.disable() } }
          )
        )
        .disabled(!service.isConfigured || (service.isSyncing && !service.isEnabled))
        .accessibilityIdentifier("cloudSyncToggle")
        .confirmationDialog(
          preferences.text("cloud.enableTitle"), isPresented: $confirmEnable,
          titleVisibility: .visible
        ) {
          Button(preferences.text("cloud.enableConfirm")) { Task { await service.enable() } }
          Button(preferences.text("action.cancel"), role: .cancel) {}
        } message: {
          Copy("cloud.enableDetail")
        }
        LabeledContent(preferences.text("cloud.status")) {
          HStack {
            if service.isSyncing { ProgressView().controlSize(.small) }
            Copy(service.statusKey).foregroundStyle(.secondary)
          }
        }.accessibilityIdentifier("cloudSyncStatus")
        if service.isEnabled {
          LabeledContent(preferences.text("cloud.pending")) {
            Text(service.pendingCount, format: .number).monospacedDigit()
          }
        }
        if let date = service.lastSync {
          LabeledContent(preferences.text("cloud.lastSync")) {
            Text(date, format: .dateTime.month().day().hour().minute()).monospacedDigit()
          }
        }
        if let date = service.nextRetryAt {
          LabeledContent(preferences.text("cloud.nextRetry")) {
            Text(date, format: .dateTime.hour().minute().second()).monospacedDigit()
          }
        }
        if service.isEnabled {
          Button(preferences.text("cloud.syncNow")) { Task { await service.syncNow() } }
            .disabled(service.isSyncing || !service.isForeground)
            .accessibilityIdentifier("cloudSyncNow")
        }
      } footer: {
        Copy("cloud.localFirst")
      }
      Section {
        SymbolLabel(key: "cloud.scope", symbol: "server.rack")
        SymbolLabel(key: "cloud.credentialsExcluded", symbol: "key")
        Copy("cloud.preferencesExcluded").foregroundStyle(.secondary)
      } header: {
        Copy("cloud.scopeTitle")
      } footer: {
        Copy("cloud.conflictPolicy")
      }
      if !service.isConfigured {
        Section { Copy("cloud.configurationRequired").foregroundStyle(.secondary) }
      }
      if service.isConfigured {
        Section {
          Button(preferences.text("cloud.deleteCopy"), role: .destructive) { confirmDelete = true }
            .disabled(service.isSyncing)
            .accessibilityIdentifier("cloudDeleteCopy")
            .confirmationDialog(
              preferences.text("cloud.deleteTitle"), isPresented: $confirmDelete,
              titleVisibility: .visible
            ) {
              Button(preferences.text("cloud.deleteConfirm"), role: .destructive) {
                Task { await service.deleteCloudCopy() }
              }
              Button(preferences.text("action.cancel"), role: .cancel) {}
            } message: {
              Copy("cloud.deleteDetail")
            }
          if service.cloudCopyDeleted { Copy("cloud.copyDeleted").foregroundStyle(.secondary) }
        } footer: {
          Copy("cloud.deleteDetail")
        }
      }
    } else {
      Section { Copy("storage.error.unavailable").foregroundStyle(.secondary) }
    }
  }
}
