import Foundation
import Observation
import ZeroCore

/// The file tree's own state — which folders are expanded, what they contain, which file is
/// open — kept separate from `FileTreePanel`/`FileTreeRow` themselves.
///
/// Owned by `RootView` as a plain `@State`, so it survives `FileTreePanel` being conditionally
/// removed from the view tree when the panel is toggled closed. A view's own `@State` is torn
/// down the moment SwiftUI removes it from the hierarchy — that's what made closing and reopening
/// the panel lose your place (which folders you'd expanded, which file you were reading) before
/// this existed. The fix is this state living one level up, in something that never gets removed.
@Observable
final class FileTreeState {
    var root: URL?
    var matcher: GitignoreMatcher = .empty
    var rootEntries: [WorkspaceEntry]?
    var expandedFolders: Set<URL> = []
    var childrenCache: [URL: [WorkspaceEntry]] = [:]
    var selectedFile: WorkspaceEntry?

    /// Uncommitted-change status per file, keyed by path relative to `root` — the tree's diff
    /// indicators. Empty when the workspace isn't a git repository, or the read simply hasn't
    /// completed yet; either way, nothing is marked changed, which is the same as "nothing to
    /// show" rather than an error state.
    var gitStatus: [String: GitFileStatus] = [:]
    /// `gitStatus` rolled up to every ancestor folder that contains a change
    /// (`GitFileStatus.rollup(_:)`) — computed once per load, not per row.
    var gitStatusByFolder: [String: GitFileStatus] = [:]

    /// Clears everything when the workspace root actually changes (a different session) — a
    /// no-op otherwise, which is what makes reopening the *same* session's tree free: nothing
    /// here gets thrown away just because the panel was hidden and shown again.
    func resetIfRootChanged(to newRoot: URL) {
        guard root != newRoot else { return }
        root = newRoot
        rootEntries = nil
        expandedFolders = []
        childrenCache = [:]
        selectedFile = nil
        gitStatus = [:]
        gitStatusByFolder = [:]
    }
}
