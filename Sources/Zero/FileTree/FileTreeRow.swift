import SwiftUI
import ZeroCore

/// One row in the tree, and — recursively — the rows for whatever's expanded beneath it.
///
/// Not `DisclosureGroup`: its native macOS indentation is generous enough (built for a settings
/// form, not a dense file list) that a few levels of nesting reads as a wall of blank leading
/// space. This owns its own indent explicitly — `depth * 14pt` — the same tight-per-level spacing
/// a file tree like VS Code's actually uses.
///
/// Expansion state and a folder's already-read children live in `state` (`FileTreeState`), not
/// local `@State` — that's what lets them survive the panel being closed and reopened.
struct FileTreeRow: View {
    let entry: WorkspaceEntry
    let root: URL
    let matcher: GitignoreMatcher
    let depth: Int
    let state: FileTreeState
    let onSelectFile: (WorkspaceEntry) -> Void

    @Environment(\.colorScheme) private var scheme

    private var isExpanded: Bool { state.expandedFolders.contains(entry.url) }

    /// This row's diff indicator — the entry's own status for a file, the rolled-up status of its
    /// descendants for a folder (PRD addendum: "a modified/added file or folder must show a diff
    /// color"). `nil` reads as "unchanged," rendered as the ordinary foreground color.
    private var gitStatus: GitFileStatus? {
        let relativePath = WorkspaceTree.relativePath(of: entry.url, root: root)
        return entry.isDirectory ? state.gitStatusByFolder[relativePath] : state.gitStatus[relativePath]
    }

    private var nameColor: Color {
        switch gitStatus {
        case .added: Theme.Syntax.added(scheme)
        case .modified: Theme.Syntax.modified(scheme)
        case nil: Theme.foreground(scheme)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if entry.isDirectory, isExpanded, let children = state.childrenCache[entry.url] {
                ForEach(children) { child in
                    FileTreeRow(
                        entry: child, root: root, matcher: matcher, depth: depth + 1,
                        state: state, onSelectFile: onSelectFile
                    )
                }
            }
        }
        // Off the main actor, same reasoning as every other read in this feature
        // (`004-composer-input-lag`). Re-checked whenever this folder's expansion flips; a no-op
        // once its children are already cached — the common case on reopen.
        .task(id: isExpanded) {
            guard entry.isDirectory, isExpanded, state.childrenCache[entry.url] == nil else { return }
            let matcher = matcher
            let url = entry.url
            let root = root
            let result = await Task.detached {
                try? WorkspaceTree.children(of: url, root: root, ignoring: matcher)
            }.value
            state.childrenCache[url] = result ?? []
        }
    }

    private var row: some View {
        Button {
            if entry.isDirectory {
                if isExpanded {
                    state.expandedFolders.remove(entry.url)
                } else {
                    state.expandedFolders.insert(entry.url)
                }
            } else {
                onSelectFile(entry)
            }
        } label: {
            HStack(spacing: 4) {
                Group {
                    if entry.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    } else {
                        Color.clear
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.secondary(scheme))
                .frame(width: 10)

                Image(systemName: entry.isDirectory ? FileIcon.folder(expanded: isExpanded) : FileIcon.symbol(forFileNamed: entry.name))
                    .font(.callout)
                    .foregroundStyle(Theme.secondary(scheme))
                    .frame(width: 16)

                Text(entry.name)
                    .font(.callout)
                    .foregroundStyle(nameColor)
                    // Live watching means this color can change under the user's eyes — a git
                    // status flipping from clean to modified while the panel is open. A quiet
                    // cross-fade reads as "this updated," a hard cut reads as a glitch. Same
                    // `Theme.Motion.value` token a changing value already uses elsewhere
                    // (`UsageIndicator`'s figures).
                    .zeroAnimation(Theme.Motion.value, value: gitStatus)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
