import SwiftUI
import ZeroCore

/// The conversation: transcript above, composer below, and the permission prompt in between when
/// the agent is blocked on the user.
struct ConversationPane: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool
    /// Local on purpose — see the note in `AppModel`. Typing must not touch the observable graph.
    @State private var draft = ""

    var body: some View {
        if let project = model.selectedProject, model.selectedSession == nil {
            ComposeView(project: project, model: model, coordinator: coordinator)
        } else if let session = model.selectedSession {
            VStack(spacing: 0) {
                TranscriptView(entries: session.events)
                if let request = session.pendingPermission {
                    Divider()
                    PermissionPrompt(request: request) { option in
                        coordinator.answerPermission(sessionID: session.id, option: option)
                    }
                }
                composer(session: session)
            }
            .zeroSurface(scheme)
        } else {
            EmptyStatePane(
                title: "No project open",
                detail: "Add a repository from the sidebar. Each session gets its own git worktree inside it."
            )
        }
    }

    /// The composer.
    ///
    /// One raised, rounded surface holding the field and its controls, rather than a bare row with a
    /// button beside it. The controls sit inside the box because they act on what is in it — putting
    /// them outside makes the box a form field, and this is the main thing on the screen.
    private func composer(session: AppModel.SessionSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($composerFocused)
                    .accessibilityLabel("Message to \(session.title)")
                    .onSubmit(send)

                // Usage sits immediately left of the send control — the two things that live at
                // the end of every message: what it costs, and the button that sends it.
                UsageIndicator(usage: session.usage)

                if model.selectedSession?.state == .running {
                    circleButton(systemImage: "stop.fill", label: "Stop") {
                        Task { await coordinator.cancelTurn(session.id) }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Interrupt the turn without ending the session")
                } else {
                    circleButton(systemImage: "arrow.up", label: "Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.foreground(scheme).opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.foreground(scheme).opacity(composerFocused ? 0.32 : 0.14), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: composerFocused)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    /// The single round control at the end of the field. Filled, because it is the one action here.
    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.background(scheme))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.foreground(scheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = model.selectedSessionID else { return }
        draft = ""
Task { await coordinator.send(text, to: id) }
    }
}
