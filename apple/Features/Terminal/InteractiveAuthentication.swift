import Foundation
import SSHCoreBridge
import SwiftUI

struct InteractiveChallenge: Identifiable {
  let sessionID: UUID
  let requestID: UInt64
  let target: ConnectionTarget
  let name: String
  let instructions: String
  let prompts: [AuthenticationPrompt]
  var id: String { "\(sessionID.uuidString).\(requestID)" }
}

struct InteractiveAuthenticationSheet: View {
  @Environment(AppPreferences.self) private var preferences
  @Environment(WorkspaceState.self) private var workspace
  let challenge: InteractiveChallenge
  @State private var responses: [String] = []

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            verbatim:
              "\(challenge.target.username)@\(challenge.target.host):\(challenge.target.port)"
          )
          .font(.headline).textSelection(.enabled)
          Copy("ssh.interactive.notice").foregroundStyle(.secondary)
          if !challenge.name.isEmpty { Text(verbatim: challenge.name) }
          if !challenge.instructions.isEmpty { Text(verbatim: challenge.instructions) }
        }
        ForEach(Array(challenge.prompts.enumerated()), id: \.offset) { index, prompt in
          if index < responses.count {
            let binding = Binding(
              get: { responses[index] }, set: { responses[index] = String($0.prefix(2048)) })
            if prompt.echo {
              TextField(text: binding) { Text(verbatim: prompt.prompt) }.autocorrectionDisabled()
            } else {
              SecureField(text: binding) { Text(verbatim: prompt.prompt) }
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(preferences.text("ssh.interactive.title"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(preferences.text("action.cancel")) { submit(nil) }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(preferences.text("ssh.interactive.respond")) { submit(responses) }
            .disabled(responses.count != challenge.prompts.count)
            .accessibilityIdentifier("authenticationRespond")
        }
      }
    }
    .onAppear { responses = Array(repeating: "", count: challenge.prompts.count) }
    .onDisappear { responses.removeAll() }
    .interactiveDismissDisabled()
    #if os(macOS)
      .frame(width: 600, height: 440)
    #endif
  }
  private func submit(_ answers: [String]?) {
    workspace.answerAuthentication(challenge, responses: answers)
    responses.removeAll()
  }
}
