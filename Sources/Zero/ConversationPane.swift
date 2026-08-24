import SwiftUI
import ZeroCore

/// The conversation: transcript above, composer below, and — when the agent is blocked on the user
/// — the permission prompt between them, over the mode row rather than under it.
struct ConversationPane: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let project = model.selectedProject, model.selectedSession == nil {
            ComposeView(project: project, model: model, coordinator: coordinator)
        } else if let session = model.selectedSession {
            VStack(spacing: 0) {
                TranscriptView(entries: session.events)
                if let request = session.pendingPermission {
                    // Above the mode row, not below it: the card is a question to answer now, and
                    // the mode row belongs to the message you send next. No divider either — the
                    // card carries its own border and margin, matching the composer's own floating
                    // surfaces rather than a bar wedged between two panes.
                    PermissionPrompt(request: request) { option in
                        coordinator.answerPermission(sessionID: session.id, option: option)
                    }
                    // Its own gap below, so the card never sits flush against the pills.
                    .padding(.bottom, 12)
                    // It rises from the composer edge, because a question that blocks the agent
                    // arriving silently is a question that gets missed (FR-20.3).
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                modeRow(session: session)
                composer(session: session)
            }
            .zeroAnimation(Theme.Motion.arrival, value: session.pendingPermission?.id)
            .zeroSurface(scheme)
        } else {
            EmptyStatePane(
                title: "No project open",
                detail: "Add a repository from the sidebar. Each session gets its own git worktree inside it."
            )
        }
    }

    /// The permission mode row, directly above the composer inside the same surface — visible
    /// for as long as a session is open, not tucked into the collapsible inspector (see the PRD's
    /// UI/UX notes: this is a decision made as often as the provider is).
    private func modeRow(session: AppModel.SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                PermissionModeControl(mode: session.permissionMode) { mode in
                    Task { await coordinator.setPermissionMode(mode, for: session.id) }
                }
                Spacer(minLength: 0)
            }
            if session.permissionMode == .bypass {
                BypassWarning()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .zeroMeasure()
    }

    /// The composer, and the one control whose meaning changes with the session: Send becomes Stop
    /// while the agent is running, in the same place, because interrupting is what you reach for at
    /// exactly the moment sending is unavailable.
    private func composer(session: AppModel.SessionSnapshot) -> some View {
        Composer(
            placeholder: "Reply",
            fieldLabel: "Message to \(session.title)",
            usage: session.usage
        ) { text in
            guard let id = model.selectedSessionID else { return }
            Task { await coordinator.send(text, to: id) }
        } trailing: { submit, enabled in
            if session.state == .running {
                CircleButton(systemImage: "stop.fill", label: "Stop") {
                    Task { await coordinator.cancelTurn(session.id) }
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Interrupt the turn without ending the session")
            } else {
                CircleButton(systemImage: "arrow.up", label: "Send", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!enabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .zeroMeasure()
    }
}
