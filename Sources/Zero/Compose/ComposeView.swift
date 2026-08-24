import SwiftUI
import ZeroCore

/// Starting work in a project: the question, the box, and what will answer it.
///
/// No modal. The repository is already chosen — it is the project you selected — so a sheet asking
/// for it again would be asking a question that has already been answered.
struct ComposeView: View {
    let project: AppModel.Project
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme
    @State private var starting = false
    /// Local, and reset after every start (see `start()`) rather than living on `AppModel` beside
    /// `draftProvider`/`draftModel`: those two are deliberately remembered between sessions, but
    /// the PRD for permission modes is explicit that a new session always starts at `.ask`.
    @State private var draftPermissionMode: PermissionMode = .ask

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                Text("What should be built in \(project.name)?")
                    .font(Theme.display(.title))
                    .tracking(Theme.displayTracking)

                // Literally the same box as the reply composer: starting a session and continuing
                // one are the same act, so they are the same component.
                Composer(
                    placeholder: "Describe the task",
                    fieldLabel: "Task for \(project.name)",
                    usage: Usage(),
                    canSubmit: canStart,
                    autofocus: true,
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
                    PermissionModeControl(mode: draftPermissionMode) { draftPermissionMode = $0 }
                    Spacer(minLength: 0)
                }
                if draftPermissionMode == .bypass {
                    BypassWarning()
                }

                if let reason = coordinator.unavailableReason(for: model.draftProvider) {
                    // The reason, not a generic "unavailable": a fixable setup problem should read as
                    // fixable.
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(Theme.secondary(scheme))
                }
            }
            .zeroMeasure(Theme.composeMeasure)
            .padding(28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zeroSurface(scheme)
    }

    /// Everything except "the field has text in it", which `Composer` decides.
    private var canStart: Bool {
        !starting
            && coordinator.isAvailable(model.draftProvider)
            && !model.draftModel.isEmpty
    }

    private func start(prompt: String) {
        guard canStart, let descriptor = coordinator.descriptor(for: model.draftProvider) else { return }
        let mode = draftPermissionMode
        draftPermissionMode = .ask
        starting = true
        Task {
            await coordinator.startSession(
                repository: project.id,
                provider: descriptor,
                model: model.draftModel,
                prompt: prompt,
                workspace: model.draftWorkspace,
                permissionMode: mode
            )
            starting = false
        }
    }
}
