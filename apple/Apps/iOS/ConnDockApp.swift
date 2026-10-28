import ConnDockKit
import SwiftUI

@main
struct ConnDockApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var preferences = AppPreferences.forCurrentProcess()
  @State private var workspace = WorkspaceState()

  var body: some Scene {
    WindowGroup {
      WorkspaceRoot()
        .environment(preferences)
        .environment(workspace)
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background { workspace.setApplicationBackgrounded(true) }
      if phase == .active { workspace.setApplicationBackgrounded(false) }
      workspace.setApplicationActive(phase == .active)
    }
  }
}
