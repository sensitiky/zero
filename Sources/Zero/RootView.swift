import SwiftUI
import ZeroCore

/// The shell: projects and their sessions on the left, the active conversation beside them.
struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

    /// Owned here, not inside `FileTreePanel` — see `FileTreeState`'s doc comment for why: this
    /// is what lets closing and reopening the panel keep your place instead of losing it.
    @State private var fileTreeState = FileTreeState()
    @State private var fileTreeWidth: CGFloat = 280

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SessionSidebar(model: model, coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            // A plain HStack, not a third NavigationSplitView column: toggleable and costs
            // nothing hidden, rather than a permanent column always taking space (PRD
            // docs/prds/007-file-tree-sidebar/PRD.md, and the precedent in UsageIndicator.swift
            // against a permanent inspector).
            HStack(spacing: 0) {
                ConversationPane(model: model, coordinator: coordinator)
                if model.showsFileTree, let session = model.selectedSession {
                    ResizableDivider(width: $fileTreeWidth, range: 200...520)
                    FileTreePanel(root: URL(fileURLWithPath: session.worktreePath), state: fileTreeState)
                        .frame(width: fileTreeWidth)
                }
            }
        }
        .zeroSurface(scheme)
        .onAppear { StartupClock.reportFirstFrame() }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { coordinator.lastError != nil },
                set: { if !$0 { coordinator.lastError = nil } }
            )
        ) {
            Button("OK") { coordinator.lastError = nil }
        } message: {
            // Shown verbatim: a provider that will not start says why, and paraphrasing that into
            // "an error occurred" throws away the only thing that helps.
            Text(coordinator.lastError ?? "")
        }

    }
}

/// Shown when nothing is selected.
struct EmptyStatePane: View {
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.display(.title2))
                .tracking(Theme.displayTracking)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.secondary(scheme))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zeroSurface(scheme)
    }
}
