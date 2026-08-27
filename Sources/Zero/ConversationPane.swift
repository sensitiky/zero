import SwiftUI
import ZeroCore

/// The conversation: transcript above, composer below, and — when the agent is blocked on the user
/// — the permission prompt between them, over the mode row rather than under it.
struct ConversationPane: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme
    /// Drives the handoff popover, opened either from the exhaustion card's action or from the
    /// always-available trigger in `modeRow` (010-provider-handoff, FR-3/FR-4).
    @State private var showingHandoff = false

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
                } else if session.contextExhausted {
                    // Same slot `PermissionPrompt` uses, for the same reason: a card here rises
                    // right where the next message would go, rather than as one more line lost in
                    // scrollback.
                    ContextExhaustedCard(
                        continueAction: { showingHandoff = true },
                        dismiss: { model.dismissContextExhausted(sessionID: session.id) }
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                modeRow(session: session)
                composer(session: session)
            }
            .zeroAnimation(Theme.Motion.arrival, value: session.pendingPermission?.id)
            .zeroAnimation(Theme.Motion.arrival, value: session.contextExhausted)
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
                // Always available, not only when `session.contextExhausted` — the auto-offered
                // card above is one way in, this is the other (010-provider-handoff, FR-4).
                Button {
                    showingHandoff = true
                } label: {
                    Image(systemName: "arrow.turn.up.right")
                }
                .buttonStyle(.borderless)
                .help("Continue this conversation in a new session, on another provider or model")
                .accessibilityLabel("Continue this conversation in a new session")
                .popover(isPresented: $showingHandoff, arrowEdge: .bottom) {
                    // A popover is already a floating container, same reasoning as the usage ring
                    // and the bridge panel — no second rounded panel nested inside itself.
                    HandoffSheet(
                        source: session,
                        model: model,
                        coordinator: coordinator,
                        dismiss: { showingHandoff = false }
                    )
                    .presentationBackground(.thickMaterial)
                }
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
            usage: session.usage,
            // A restored session whose folder is gone can't be sent to — nothing would receive
            // it. `openSession` already left a notice explaining why (PRD FR-9).
            canSubmit: !session.folderMissing
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
