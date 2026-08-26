import Foundation

/// A path resolved outside the root it was checked against.
public enum PathContainmentError: Error, Sendable, Equatable {
    case outsideRoot(path: String, root: String)
}

/// Confirms a path falls under a given root, symlinks and `..` included — the one check every
/// place in this app that touches a path derived from something other than its own fixed
/// configuration has to make.
///
/// Extracted from `GitService`, which had this same logic `private` and worktree-flavored before
/// `WorkspaceTree`/`WorkspaceFileReader` (`007-file-tree-sidebar`) needed an identical guarantee
/// for reading arbitrary file content that never touches git. One implementation, so the two
/// callers can't quietly drift into different definitions of "contained."
public enum PathContainment {
    /// Throws `PathContainmentError.outsideRoot` if `path`, once symlinks are resolved and `..`
    /// components are collapsed, does not fall under `root` (resolved the same way).
    public static func validate(_ path: URL, isUnder root: URL) throws {
        let rootResolved = try resolveFully(root.path)
        let pathResolved = try resolveFully(path.path)

        guard pathResolved.hasPrefix(rootResolved) else {
            throw PathContainmentError.outsideRoot(path: path.path, root: root.path)
        }

        // A proper subdirectory, not a prefix match on directory names — `/repo/secret` is not a
        // child of `/repo-evil`.
        if pathResolved != rootResolved {
            let afterRoot = String(pathResolved.dropFirst(rootResolved.count))
            guard afterRoot.hasPrefix("/") || afterRoot.isEmpty else {
                throw PathContainmentError.outsideRoot(path: path.path, root: root.path)
            }
        }
    }

    /// Resolves a path by expanding symlinks and normalizing `..` components, one path component
    /// at a time, so a symlink partway through the path (not just at its tail) is still caught.
    static func resolveFully(_ path: String) throws -> String {
        let fileManager = FileManager.default
        let normalized = (path as NSString).standardizingPath

        guard normalized.hasPrefix("/") else {
            throw PathContainmentError.outsideRoot(path: path, root: path)
        }

        var resolved = ""
        var visited = Set<String>()

        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            resolved += "/" + component

            guard !visited.contains(resolved) else {
                throw PathContainmentError.outsideRoot(path: path, root: resolved)
            }
            visited.insert(resolved)

            if let target = try? fileManager.destinationOfSymbolicLink(atPath: resolved) {
                if target.hasPrefix("/") {
                    resolved = target
                } else {
                    let parent = (resolved as NSString).deletingLastPathComponent
                    resolved = (parent as NSString).appendingPathComponent(target)
                }
                resolved = (resolved as NSString).standardizingPath
            }
        }

        return resolved.isEmpty ? "/" : resolved
    }
}
