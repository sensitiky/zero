import Foundation

/// A file's working-tree status against `HEAD`, as `git status --porcelain` reports it — the
/// three kinds a file tree can actually show something for (`007-file-tree-sidebar` diff
/// indicators). Deleted files are deliberately absent from this enum: a tree walks what's on
/// disk, and a file `git status` reports deleted no longer exists there to have a row at all.
public enum GitFileStatus: Sendable, Equatable {
    /// Tracked, with uncommitted changes (staged, unstaged, or both).
    case modified
    /// Not tracked, or staged as new — no version exists at `HEAD` to diff against.
    case added

    /// Rolls a file-level status map up to every ancestor folder that contains at least one
    /// changed file — the file tree's "this folder has something changed inside it" indicator.
    /// A folder with both a modified and an added descendant reads as `.modified`: "something
    /// changed here" is the more urgent fact than "and also something new."
    public static func rollup(_ fileStatus: [String: GitFileStatus]) -> [String: GitFileStatus] {
        var folders: [String: GitFileStatus] = [:]
        for (path, status) in fileStatus {
            var components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            components.removeLast()

            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if status == .modified {
                    folders[prefix] = .modified // always wins, even over an already-recorded .added
                } else if folders[prefix] == nil {
                    folders[prefix] = .added
                }
            }
        }
        return folders
    }
}
