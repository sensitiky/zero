import SwiftUI
import ZeroCore

/// The conversation: transcript above, composer below, and the permission prompt in between when
/// the agent is blocked on the user.
struct ConversationPane: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                TranscriptView(entries: session.events)
                if let request = session.pendingPermission {
                    Divider()
                    PermissionPrompt(request: request) { option in
                        coordinator.answerPermission(sessionID: session.id, option: option)
                    }
                }
                Divider()
                composer(sessionTitle: session.title, sessionID: session.id)
            }
            .zeroSurface(scheme)
        } else {
            EmptyStatePane(
                title: "No session selected",
                detail: "Describe a task and pick an agent. Each session gets its own git worktree."
            )
        }
    }

    private func composer(sessionTitle: String, sessionID: UUID) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .accessibilityLabel("Message to \(sessionTitle)")
                .onSubmit(send)
            if model.selectedSession?.state == .running {
                Button("Stop") { Task { await coordinator.cancelTurn(sessionID) } }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Interrupt the turn without ending the session")
            }
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = model.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = model.selectedSessionID else { return }
        model.composerText = ""
        Task { await coordinator.send(text, to: id) }
    }
}
