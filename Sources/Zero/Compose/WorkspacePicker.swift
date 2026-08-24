import SwiftUI
import ZeroCore

/// Where the session works.
///
/// Two genuinely different jobs, so it is a choice rather than a default with a warning: continue
/// what you are doing, or run something beside it.
struct WorkspacePicker: View {
    @Bindable var model: AppModel

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
