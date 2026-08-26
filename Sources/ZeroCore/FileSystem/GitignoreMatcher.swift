import Foundation

/// A parsed `.gitignore`, matching the subset this app supports.
///
/// **Supported:** exact names (`build`), `*` glob wildcards (`*.log`), a trailing `/` meaning
/// "directory only" (`dist/`), and a leading `**/` meaning "at any depth" even for a pattern that
/// contains another `/` (`**/fixtures/*.json`). A pattern with no interior `/` already matches at
/// any depth on its own — real gitignore's own rule, not something `**/` has to spell out for the
/// common case (`node_modules`, `*.log`). A pattern with an interior `/` and no leading `**/` is
/// root-relative: it matches the full path from the workspace root, not just the entry's name.
///
/// **Not supported:** negation (`!pattern`), nested per-directory `.gitignore` files,
/// `.git/info/exclude`, and the global gitignore. A repository whose ignore rules genuinely need
/// any of those will show files this matcher doesn't hide that `git status` would — a stated
/// limitation (`docs/prds/007-file-tree-sidebar/PRD.md` Non-goals), not a silent one. Full
/// gitignore semantics are notoriously fiddly (`git check-ignore` itself is the only fully
/// faithful implementation); this covers the patterns real repositories overwhelmingly use.
public struct GitignoreMatcher: Sendable {
    private struct Pattern {
        let glob: String
        let directoryOnly: Bool
        /// Whether `glob` must match the full relative path from the workspace root (it has an
        /// interior `/` and no leading `**/`) rather than just the entry's own name.
        let rootRelative: Bool
        /// Whether the line had a leading `**/` — a root-relative-looking pattern that should
        /// still match starting at any depth, not only from the workspace root.
        let anyDepth: Bool
    }

    private let patterns: [Pattern]

    /// An empty matcher — nothing is ignored beyond what `WorkspaceTree` always excludes
    /// regardless (`.git`, `.DS_Store`).
    public static let empty = GitignoreMatcher(patterns: "")

    public init(patterns text: String) {
        self.patterns = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line -> Pattern in
                var glob = line
                let directoryOnly = glob.hasSuffix("/")
                if directoryOnly { glob.removeLast() }
                let anyDepth = glob.hasPrefix("**/")
                if anyDepth { glob.removeFirst(3) }
                return Pattern(
                    glob: glob, directoryOnly: directoryOnly,
                    rootRelative: glob.contains("/"), anyDepth: anyDepth
                )
            }
    }

    /// Whether `relativePath` (slash-separated, relative to the workspace root, no leading slash)
    /// matches any pattern.
    public func matches(relativePath: String, isDirectory: Bool) -> Bool {
        for pattern in patterns {
            if pattern.directoryOnly, !isDirectory { continue }
            for candidate in candidates(for: pattern, relativePath: relativePath) {
                if fnmatch(pattern.glob, candidate) { return true }
            }
        }
        return false
    }

    /// The path suffixes worth trying `pattern.glob` against.
    ///
    /// No interior slash → the pattern already matches at any depth on its own (real gitignore
    /// semantics): try just the entry's name. An interior slash with no `**/` prefix →
    /// root-relative: try only the full path. An interior slash *with* a `**/` prefix (e.g.
    /// `**/fixtures/*.json`) → still any-depth, just multi-segment: try every suffix starting at a
    /// path-segment boundary, so it can match starting partway through the tree, not only from
    /// the root.
    private func candidates(for pattern: Pattern, relativePath: String) -> [String] {
        guard pattern.rootRelative else {
            return [(relativePath as NSString).lastPathComponent]
        }
        guard pattern.anyDepth else {
            return [relativePath]
        }
        let segments = relativePath.split(separator: "/")
        return (0..<segments.count).map { segments[$0...].joined(separator: "/") }
    }

    /// A small, dependency-free glob: `*` matches any run of characters, everything else is
    /// literal. No attempt at `?`, `[abc]`, or any other glob syntax — not in the stated subset.
    private func fnmatch(_ glob: String, _ text: String) -> Bool {
        let globParts = glob.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard globParts.count > 1 else { return glob == text }

        var remaining = Substring(text)
        for (index, part) in globParts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard remaining.hasPrefix(part) else { return false }
                remaining.removeFirst(part.count)
            } else if index == globParts.count - 1 {
                return remaining.hasSuffix(part)
            } else {
                guard let range = remaining.range(of: part) else { return false }
                remaining = remaining[range.upperBound...]
            }
        }
        return true
    }
}
