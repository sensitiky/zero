import SwiftUI
import ZeroCore

/// The panel's root: the tree by default, swapping to a file's preview when one is selected.
///
/// Tree and preview share one panel rather than sitting side by side — the panel's width doesn't
/// have to hold both a narrow tree and a wide code view at once (PRD UI/UX notes).
///
/// Holds no state of its own — everything (expanded folders, cached children, the selected file)
/// lives in `state`, owned above where this panel is toggled, so closing and reopening the panel
/// doesn't lose your place. See `FileTreeState`'s doc comment.
///
/// Live-watches `root` (`WorkspaceWatcher`) while it's on screen, so a file changed by the agent,
/// by hand, or by `git` shows up without the user having to close and reopen the panel. The
/// watcher lives here, not in `FileTreeState` — it's exactly the kind of background work that
/// should stop the moment the panel is hidden, the same "costs nothing hidden" reasoning the PRD
/// already applies to the panel as a whole.
struct FileTreePanel: View {
    /// The session's actual workspace — `worktreePath`, already correct for both
    /// `.currentCheckout` and `.isolatedWorktree` sessions (PRD FR-2).
    let root: URL
    let state: FileTreeState

    @State private var watcher: WorkspaceWatcher?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let selectedFile = state.selectedFile {
                let relativePath = WorkspaceTree.relativePath(of: selectedFile.url, root: root)
                FilePreviewView(
                    entry: selectedFile, root: root, gitStatus: state.gitStatus[relativePath]
                ) { state.selectedFile = nil }
            } else {
                tree
            }
        }
        // Re-reads only when the session (and so the workspace root) actually changes —
        // `resetIfRootChanged` is a no-op otherwise, which is what makes reopening the same
        // session's tree free rather than a fresh directory read every time.
        .task(id: root) {
            await load()
            watch()
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
        }
    }

    @ViewBuilder
    private var tree: some View {
        switch state.rootEntries {
        case nil:
            Color.clear
        case .some(let entries) where entries.isEmpty:
            emptyState
        case .some(let entries):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        FileTreeRow(entry: entry, root: root, matcher: state.matcher, depth: 0, state: state) { file in
                            state.selectedFile = file
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing to show")
            .font(.callout)
            .foregroundStyle(Theme.secondary(scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The initial read for a session: a no-op if this root is already loaded (reopening the
    /// panel on the same session).
    private func load() async {
        state.resetIfRootChanged(to: root)
        guard state.rootEntries == nil else { return }
        await reload()
    }

    /// Starts watching `root` for changes, reloading (without disturbing `expandedFolders` or
    /// `selectedFile` — see `reload()`) whenever something does.
    private func watch() {
        watcher = WorkspaceWatcher(root: root) {
            Task { @MainActor in await reload() }
        }
    }

    /// Off the main actor: a `.gitignore` read, a directory listing, the working-tree git status
    /// (best-effort — a workspace that isn't a git repository just gets no diff indicators), and a
    /// fresh listing for every folder the user currently has expanded, so a live change inside an
    /// open folder shows up too. Never touches `expandedFolders` or `selectedFile` — those are the
    /// user's place in the tree, not something a background refresh gets to reset.
    private func reload() async {
        let root = root
        let expandedFolders = Array(state.expandedFolders)
        let result = await Task.detached {
            () -> (GitignoreMatcher, [WorkspaceEntry], [String: GitFileStatus], [URL: [WorkspaceEntry]]) in
            let gitignorePath = root.appendingPathComponent(".gitignore")
            let patterns = (try? String(contentsOf: gitignorePath, encoding: .utf8)) ?? ""
            let matcher = GitignoreMatcher(patterns: patterns)
            let entries = (try? WorkspaceTree.children(of: root, root: root, ignoring: matcher)) ?? []
            var gitStatus: [String: GitFileStatus] = [:]
            if let gitService = try? GitService(repositoryPath: root) {
                gitStatus = (try? await gitService.workingTreeStatus()) ?? [:]
            }
            var expandedChildren: [URL: [WorkspaceEntry]] = [:]
            for folder in expandedFolders {
                expandedChildren[folder] = (try? WorkspaceTree.children(of: folder, root: root, ignoring: matcher)) ?? []
            }
            return (matcher, entries, gitStatus, expandedChildren)
        }.value

        let (matcher, entries, gitStatus, expandedChildren) = result
        state.matcher = matcher
        state.rootEntries = entries
        state.gitStatus = gitStatus
        state.gitStatusByFolder = GitFileStatus.rollup(gitStatus)
        for (folder, children) in expandedChildren {
            state.childrenCache[folder] = children
        }
        // The transition itself lives on the row (`FileTreeRow`'s `.zeroAnimation`, keyed to its
        // own status) rather than here — a plain state write animates nothing on its own, and
        // wrapping it in `withAnimation` is exactly what `Scripts/lint-design-tokens.sh` exists to
        // catch: reduced-motion has to be honoured per view, which `.zeroAnimation` does and a bare
        // `withAnimation` block does not.
    }
}
