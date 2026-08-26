import Foundation
import Testing

@testable import ZeroCore

@Suite("WorkspaceTree")
struct WorkspaceTreeTests {
    private func makeWorkspace(
        _ paths: [String], gitignore: String = ""
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if !gitignore.isEmpty {
            try gitignore.write(
                to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
            )
        }
        return root
    }

    @Test("folders sort before files, alphabetical within each group")
    func foldersSortBeforeFiles() throws {
        let root = try makeWorkspace(["zebra.txt", "apple.txt", "Zoo/", "Bank/"])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = try WorkspaceTree.children(of: root, root: root, ignoring: .empty).map(\.name)
        #expect(names == ["Bank", "Zoo", "apple.txt", "zebra.txt"])
    }

    @Test(".git is always excluded, gitignore or not")
    func dotGitAlwaysExcluded() throws {
        let root = try makeWorkspace([".git/", "README.md"])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = try WorkspaceTree.children(of: root, root: root, ignoring: .empty).map(\.name)
        #expect(names == ["README.md"])
    }

    @Test(".DS_Store is always excluded even when .gitignore doesn't mention it")
    func dsStoreAlwaysExcluded() throws {
        let root = try makeWorkspace([".DS_Store", "README.md"], gitignore: "*.log\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let names = try WorkspaceTree.children(of: root, root: root, ignoring: GitignoreMatcher(patterns: "*.log")).map(\.name)
        // .gitignore itself is an ordinary, visible file — nothing excludes it.
        #expect(names == [".gitignore", "README.md"])
    }

    @Test("a gitignored entry is excluded")
    func gitignoredEntryExcluded() throws {
        let root = try makeWorkspace(["node_modules/", "src/"])
        defer { try? FileManager.default.removeItem(at: root) }
        let matcher = GitignoreMatcher(patterns: "node_modules")

        let names = try WorkspaceTree.children(of: root, root: root, ignoring: matcher).map(\.name)
        #expect(names == ["src"])
    }

    @Test("a symlink escaping root is skipped, not thrown")
    func symlinkEscapeSkipped() throws {
        let root = try makeWorkspace(["README.md"])
        let outside = try makeWorkspace(["secret.txt"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )

        let names = try WorkspaceTree.children(of: root, root: root, ignoring: .empty).map(\.name)
        #expect(names == ["README.md"])
    }
}
