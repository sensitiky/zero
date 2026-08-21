import SwiftUI
import ZeroCore

/// The conversation: transcript above, composer below, and the permission prompt in between when
/// the agent is blocked on the user.
struct ConversationPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                TranscriptView(entries: session.events)
                if let request = session.pendingPermission {
                    Divider()
                    PermissionPrompt(request: request) { _ in
                        model.resolvePermission(sessionID: session.id)
                    }
                }
                Divider()
                composer(sessionTitle: session.title)
            }
            .zeroSurface(scheme)
        } else {
            EmptyStatePane(
                title: "No session selected",
                detail: "Describe a task and pick an agent. Each session gets its own git worktree."
            )
        }
    }

    private func composer(sessionTitle: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .accessibilityLabel("Message to \(sessionTitle)")
                .onSubmit(send)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = model.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.composerText = ""
        // Wiring to SessionRuntime lands with D2's UI hookup; the composer is complete on its own
        // terms so the keyboard path (FR-27) can be exercised now rather than after that.
    }
}
