import Foundation

/// One entry in a workspace's file tree.
public struct WorkspaceEntry: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Lists a workspace directory one level at a time.
///
/// Deliberately not a full recursive walk: `007-file-tree-sidebar`'s tree expands folders lazily
/// as the user opens them, and a stateless "list this one directory" function is what a UI layer
/// calls repeatedly for that — the cache of what's already been expanded belongs to the view, not
/// here (see the PRD's design decisions).
public enum WorkspaceTree {
    /// The immediate children of `directory`, filtered by `matcher` and this app's own
    /// always-excluded names, sorted folders-first then localized-alphabetical within each group.
    ///
    /// - parameter root: The workspace root every listed entry must resolve under
    ///   (`PathContainment`) — `directory` is normally `root` itself or a descendant of it, but
    ///   this is the boundary a symlink inside the tree cannot be used to escape.
    /// - throws: `PathContainmentError` if `directory` itself falls outside `root`, or if reading
    ///   the directory fails.
    public static func children(
        of directory: URL,
        root: URL,
        ignoring matcher: GitignoreMatcher
    ) throws -> [WorkspaceEntry] {
        try PathContainment.validate(directory, isUnder: root)

        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)

        var entries: [WorkspaceEntry] = []
        for name in names {
            // Always excluded, gitignore or not (PRD FR-4/FR-5) — nobody browses their own git
            // internals from a file tree, and a repo that never bothered to ignore .DS_Store
            // shouldn't leak it into the one place this app shows a clean tree.
            if name == ".git" || name == ".DS_Store" { continue }

            let url = directory.appendingPathComponent(name)
            // A symlink escaping the root is skipped, not thrown — one bad entry shouldn't fail
            // the whole listing.
            guard (try? PathContainment.validate(url, isUnder: root)) != nil else { continue }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            let relativePath = relativePath(of: url, root: root)
            if matcher.matches(relativePath: relativePath, isDirectory: isDir.boolValue) { continue }

            entries.append(WorkspaceEntry(url: url, name: name, isDirectory: isDir.boolValue))
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `url`'s path relative to `root`, slash-separated, no leading slash — the form
    /// `GitignoreMatcher` and `GitFileStatus` both key their maps with.
    public static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let dropped = fullPath.dropFirst(rootPath.count)
        return String(dropped.hasPrefix("/") ? dropped.dropFirst() : dropped)
    }
}
