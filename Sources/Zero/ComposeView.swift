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
    @FocusState private var focused: Bool
    @State private var starting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                Text("What should be built in \(project.name)?")
                    .font(.title2.weight(.medium))

                TextField("Describe the task", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(3...10)
                    .focused($focused)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.foreground(scheme).opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.foreground(scheme).opacity(0.15), lineWidth: 1)
                    )

                HStack(spacing: 10) {
                    ProviderModelPicker(model: model, coordinator: coordinator)
                    WorkspacePicker(model: model)
                    Spacer(minLength: 0)
                    Button(starting ? "Starting…" : "Start") { start() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canStart)
                }

                if let reason = coordinator.unavailableReason(for: model.draftProvider) {
                    // The reason, not a generic "unavailable": a fixable setup problem should read as
                    // fixable.
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                }
            }
            .frame(maxWidth: 620)
            .padding(28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zeroSurface(scheme)
        .onAppear { focused = true }
    }

    private var canStart: Bool {
        !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !starting
            && coordinator.isAvailable(model.draftProvider)
            && !model.draftModel.isEmpty
    }

    private func start() {
        guard canStart, let descriptor = coordinator.descriptor(for: model.draftProvider) else { return }
        let prompt = model.composerText
        model.composerText = ""
        starting = true
        Task {
            await coordinator.startSession(
                repository: project.id,
                provider: descriptor,
                model: model.draftModel,
                prompt: prompt,
                workspace: model.draftWorkspace
            )
            starting = false
        }
    }
}

/// One control, two levels: providers, and inside each one its models.
///
/// Nested rather than two separate pickers because the model list depends on the provider — two flat
/// pickers let you select a pair that cannot exist.
struct ProviderModelPicker: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            ForEach(coordinator.availableProviders, id: \.descriptor.id) { entry in
                let available = coordinator.isAvailable(entry.descriptor.id)
                if entry.descriptor.knownModels.isEmpty {
                    // No verified model ids for this provider, so there is nothing honest to list.
                    Button(entry.descriptor.displayName) {
                        model.draftProvider = entry.descriptor.id
                        model.draftModel = ""
                    }
                    .disabled(!available)
                } else {
                    Menu(entry.descriptor.displayName) {
                        ForEach(entry.descriptor.knownModels, id: \.self) { name in
                            Button(name) {
                                model.draftProvider = entry.descriptor.id
                                model.draftModel = name
                            }
                        }
                    }
                    .disabled(!available)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(label)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Agent and model: \(label)")

        if coordinator.descriptor(for: model.draftProvider)?.knownModels.isEmpty == true {
            // Free text where the ids are not known first-hand, rather than a menu of guesses.
            TextField("Model", text: $model.draftModel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Model name")
        }
    }

    private var label: String {
        let provider = coordinator.descriptor(for: model.draftProvider)?.displayName ?? model.draftProvider
        return model.draftModel.isEmpty ? provider : "\(provider) · \(model.draftModel)"
    }
}

/// Where the session works.
///
/// Two genuinely different jobs, so it is a choice rather than a default with a warning: continue
/// what you are doing, or run something beside it.
struct WorkspacePicker: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            Button {
                model.draftWorkspace = .currentCheckout
            } label: {
                Text("This checkout — the agent sees your uncommitted changes")
            }
            Button {
                model.draftWorkspace = .isolatedWorktree
            } label: {
                Text("New worktree — runs beside your work, from the last commit")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.draftWorkspace == .currentCheckout ? "folder" : "arrow.triangle.branch")
                Text(model.draftWorkspace == .currentCheckout ? "This checkout" : "New worktree")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            model.draftWorkspace == .currentCheckout
                ? "The agent works in your repository and sees uncommitted changes. One session at a time."
                : "A fresh branch and worktree, starting from the last commit. Uncommitted work is not carried over."
        )
        .accessibilityLabel("Workspace: \(model.draftWorkspace == .currentCheckout ? "this checkout" : "new worktree")")
    }
}
