import SwiftUI

/// Menu commands, which are also the keyboard surface.
///
/// FR-27 requires the app be fully operable from the keyboard, and on macOS a menu command is how a
/// shortcut becomes discoverable instead of folklore.
struct ZeroCommands: Commands {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            // The visible, toggleable half of the "auto-approve routine commands" policy: the
            // checkbox is the fact that makes `PermissionOrigin.rule(_:)` legitimate rather than a
            // silent bypass — a real setting the user set, not a hardcoded allowlist. Off returns
            // to asking for every matched tool call, exactly like before this existed.
            Toggle("Ask Before Every Action", isOn: askBeforeEveryAction)
            Divider()
        }
        CommandGroup(after: .newItem) {
            // Lands on the compose state for whichever project is in context, rather than opening a
            // dialog that asks for a repository the user already chose.
            Button("New Session") {
                if let projectID = model.selectedProjectID ?? model.projects.first?.id {
                    model.selection = .project(projectID)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.projects.isEmpty)
        }
        CommandGroup(after: .sidebar) {
            Button("Next Session") { move(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { move(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }

    private var askBeforeEveryAction: Binding<Bool> {
        Binding(
            get: { !coordinator.autoApproveRoutineCommands },
            set: { coordinator.autoApproveRoutineCommands = !$0 }
        )
    }

    private func move(by offset: Int) {
        guard !model.sessions.isEmpty else { return }
        let current = model.sessions.firstIndex { $0.id == model.selectedSessionID } ?? 0
        let next = (current + offset + model.sessions.count) % model.sessions.count
        model.selection = .session(model.sessions[next].id)
    }
}
