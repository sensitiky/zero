import SwiftUI
import ZeroCore

/// Starting a session: a repository, an agent, and what you want done.
struct NewSessionSheet: View {
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var repository: URL?
    @State private var provider: String = ProviderDescriptor.claude.id
    @State private var modelName = "claude-sonnet-5"
    @State private var prompt = ""
    @State private var starting = false

    private var providers: [(descriptor: ProviderDescriptor, status: ProviderStatus)] {
        coordinator.availableProviders
    }

    private var selectedDescriptor: ProviderDescriptor? {
        providers.first { $0.descriptor.id == provider }?.descriptor
    }

    private var canStart: Bool {
        repository != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !starting
            && isAvailable(provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title3.weight(.medium))

            LabeledContent("Repository") {
                HStack {
                    Text(repository?.lastPathComponent ?? "None chosen")
                        .foregroundStyle(
                            Theme.foreground(scheme)
                                .opacity(repository == nil ? Theme.secondaryOpacity : 1)
                        )
                    Spacer()
                    Button("Choose…") { repository = coordinator.chooseRepository() }
                }
            }

            LabeledContent("Agent") {
                Picker("", selection: $provider) {
                    ForEach(providers, id: \.descriptor.id) { entry in
                        // Unavailable providers stay visible with their reason: hiding them turns a
                        // fixable setup problem into a mystery.
                        Text(label(for: entry)).tag(entry.descriptor.id)
                    }
                }
                .labelsHidden()
            }

            LabeledContent("Model") {
                TextField("", text: $modelName).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Task")
                TextField("What should the agent do?", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }

            if let reason = unavailableReason(provider) {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 460)
        .zeroSurface(scheme)
    }

    private func start() {
        guard let repository, let descriptor = selectedDescriptor else { return }
        starting = true
        let task = prompt
        Task {
            await coordinator.startSession(
                repository: repository,
                provider: descriptor,
                model: modelName,
                prompt: task
            )
            starting = false
            dismiss()
        }
    }

    private func label(for entry: (descriptor: ProviderDescriptor, status: ProviderStatus)) -> String {
        if case .available = entry.status { return entry.descriptor.displayName }
        return "\(entry.descriptor.displayName) — unavailable"
    }

    private func isAvailable(_ id: String) -> Bool {
        guard let entry = providers.first(where: { $0.descriptor.id == id }) else { return false }
        if case .available = entry.status { return true }
        return false
    }

    private func unavailableReason(_ id: String) -> String? {
        guard let entry = providers.first(where: { $0.descriptor.id == id }) else { return nil }
        switch entry.status {
        case .available: return nil
        case .notInstalled(let reason), .notAuthenticated(let reason), .resolutionFailed(let reason):
            return reason
        case .versionTooOld(let installed, let minimum, _):
            return "Installed \(installed); Zero needs \(minimum) or newer."
        }
    }
}
