import SwiftUI
import ZeroCore

/// Seed a brand-new session with this one's transcript, on whatever provider/model you pick.
///
/// Not a resume: Codex/ACP have no verified resume flag (`SessionRuntime.resume` degrades to
/// read-only for them), and even Claude Code's `--resume` only works with Claude Code on the
/// other end — a provider's session id is its own opaque handle, not something another provider
/// can be handed. This starts an ordinary new session (`SessionCoordinator.startSession`, the
/// same path `ComposeView` uses), with the prior conversation replayed as its opening prompt —
/// editable before it is ever sent, same as any composer message (010-provider-handoff).
struct HandoffSheet: View {
    let source: AppModel.SessionSnapshot
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    /// Closes the popover this is presented in. Called once `startSession` returns, success or not
    /// — a failure already lands in `coordinator.lastError`, and the source session is untouched
    /// either way (FR-7), so there is nothing this view needs to stay open for.
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var starting = false
    /// Local, not `model`'s: a new session always opens under `.ask`, the same reasoning
    /// `ComposeView.draftPermissionMode` already documents.
    @State private var permissionMode: PermissionMode = .ask
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue in a new session")
                .font(Theme.display(.title))
                .tracking(Theme.displayTracking)
            Text("The conversation from “\(source.title)” is pre-filled below. Edit it, pick who continues it, then start.")
                .font(.callout)
                .foregroundStyle(Theme.secondary(scheme))

            Composer(
                placeholder: "Opening message for the new session",
                fieldLabel: "Opening message, seeded from \(source.title)",
                usage: Usage(),
                canSubmit: canStart,
                initialText: source.transcript.handoffPrompt,
                onSubmit: start
            ) { submit, enabled in
                CircleButton(
                    systemImage: "arrow.up",
                    label: starting ? "Starting…" : "Start",
                    action: submit
                )
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
            }

            HStack(spacing: 10) {
                ProviderModelPicker(model: model, coordinator: coordinator)
                WorkspacePicker(model: model)
                Spacer(minLength: 0)
            }

            HStack {
                PermissionModeControl(mode: permissionMode) { permissionMode = $0 }
                Spacer(minLength: 0)
            }
            if permissionMode == .bypass {
                BypassWarning()
            }

            if let reason = coordinator.unavailableReason(for: model.draftProvider) {
                // Same reasoning as `ComposeView`: the fixable problem, not a generic label.
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(Theme.secondary(scheme))
            }
        }
        .padding(18)
        .frame(width: width)
    }

    private var canStart: Bool {
        !starting && coordinator.isAvailable(model.draftProvider) && !model.draftModel.isEmpty
    }

    private func start(_ prompt: String) {
        guard canStart, let descriptor = coordinator.descriptor(for: model.draftProvider) else { return }
        starting = true
        Task {
            await coordinator.startSession(
                repository: source.projectID,
                provider: descriptor,
                model: model.draftModel,
                prompt: prompt,
                workspace: model.draftWorkspace,
                permissionMode: permissionMode
            )
            starting = false
            dismiss()
        }
    }
}
