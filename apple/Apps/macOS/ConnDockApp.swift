import ConnDockKit
import SwiftUI

@main
struct ConnDockApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var preferences = AppPreferences.forCurrentProcess()
  @State private var workspace = WorkspaceState()

  var body: some Scene {
    Window("ConnDock", id: "workspace") {
      WorkspaceRoot()
        .environment(preferences)
        .environment(workspace)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1360, height: 820)
    .defaultPosition(.center)
    .windowResizability(.contentMinSize)
    .commands { WorkspaceCommands(preferences: preferences, workspace: workspace) }
    .onChange(of: scenePhase, initial: true) { _, phase in
      workspace.setApplicationActive(phase == .active)
    }

    Settings {
      SettingsScreen()
        .environment(preferences)
        .environment(workspace)
        .environment(\.locale, preferences.language.locale)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
  }
}
