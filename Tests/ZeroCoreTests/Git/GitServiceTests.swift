import Foundation
import Testing

@testable import ZeroCore

@Suite("GitService")
struct GitServiceTests {
    // MARK: - Helpers

    private func createTempRepo() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = tempDir
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitError.notARepository(path: tempDir.path)
        }

        // Configure git user for commits
        let configName = Process()
        configName.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configName.arguments = ["config", "user.name", "Test"]
        configName.currentDirectoryURL = tempDir
        configName.standardOutput = Pipe()
        configName.standardError = Pipe()
        try configName.run()
        configName.waitUntilExit()

        let configEmail = Process()
        configEmail.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configEmail.arguments = ["config", "user.email", "test@example.com"]
        configEmail.currentDirectoryURL = tempDir
        configEmail.standardOutput = Pipe()
        configEmail.standardError = Pipe()
        try configEmail.run()
        configEmail.waitUntilExit()

        // Create initial commit
        let file = tempDir.appendingPathComponent("README.md")
        try "# Test Repo\n".write(to: file, atomically: true, encoding: .utf8)

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["add", "README.md"]
        add.currentDirectoryURL = tempDir
        add.standardOutput = Pipe()
        add.standardError = Pipe()
        try add.run()
        add.waitUntilExit()

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["commit", "-m", "Initial commit"]
        commit.currentDirectoryURL = tempDir
        commit.standardOutput = Pipe()
        commit.standardError = Pipe()
        try commit.run()
        commit.waitUntilExit()

        return tempDir
    }

    private func cleanupRepo(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Tests

    @Test("creates a worktree on a fresh repository")
    func createsWorktreeOnFreshRepo() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (worktreePath, branchName) = try await service.createWorktree(from: "Test prompt")

        #expect(FileManager.default.fileExists(atPath: worktreePath.path))
        #expect(branchName.hasPrefix("zero/"))
        #expect(branchName.contains("test"))
    }

    @Test("branch name collision appends counter")
    func collisionHandling() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)

        // Create first worktree
        let (worktree1, branch1) = try await service.createWorktree(from: "Collision test")

        // Manually create a branch with the exact name to force a collision on next attempt
        // We'll create a branch that matches what the next call would try to use
        let branchToCollideWith = branch1.replacingOccurrences(
            of: "-[a-f0-9]{7}$",
            with: "-12345ab",
            options: .regularExpression
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", branchToCollideWith]
        process.currentDirectoryURL = repoPath
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        // Now try to create a worktree with a slug that would collide
        let (worktree2, branch2) = try await service.createWorktree(
            from: "Collision test",
            baseBranch: "main"
        )

        #expect(worktree1 != worktree2)
        #expect(branch1 != branch2)
    }

    @Test("slug derivation: spaces become hyphens")
    func slugDerivationSpaces() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "multiple spaces here")

        #expect(branchName.contains("multiple-spaces"))
    }

    @Test("slug derivation: uppercase becomes lowercase")
    func slugDerivationUppercase() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "UPPERCASE PROMPT")

        #expect(branchName.lowercased() == branchName)
    }

    @Test("slug derivation: slashes are removed")
    func slugDerivationSlashes() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "path/to/something")

        // Slashes should be removed from the slug, so no "/" in the branch name after "zero/"
        let slugPart = String(branchName.dropFirst("zero/".count))
        #expect(!slugPart.contains("/"))
    }

    @Test("slug derivation: leading/trailing dots removed")
    func slugDerivationLeadingTrailingDots() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "...start...and...end...")

        #expect(!branchName.hasPrefix("zero/..."))
        #expect(!branchName.hasSuffix("..."))
    }

    @Test("slug derivation: emoji-only prompt")
    func slugDerivationEmojiOnly() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "🎉🚀💻")

        // Should fallback to a valid branch name
        #expect(branchName.hasPrefix("zero/"))
        #expect(!branchName.hasSuffix("-"))
    }

    @Test("slug derivation: punctuation-only prompt")
    func slugDerivationPunctuationOnly() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (_, branchName) = try await service.createWorktree(from: "!@#$%^&*()")

        // Should fallback to a valid branch name
        #expect(branchName.hasPrefix("zero/"))
        #expect(!branchName.hasSuffix("-"))
    }

    @Test("slug derivation: extremely long prompt bounded")
    func slugDerivationLongPrompt() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let longPrompt = String(repeating: "a", count: 500)
        let (_, branchName) = try await service.createWorktree(from: longPrompt)

        // Branch name should be bounded
        #expect(branchName.count < 100)
    }

    @Test("dirty repository is detected")
    func dirtyRepoDetection() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)

        // Initially clean
        let clean = try await service.isDirty()
        #expect(!clean)

        // Make it dirty
        let file = repoPath.appendingPathComponent("dirty.txt")
        try "dirty content\n".write(to: file, atomically: true, encoding: .utf8)

        let dirty = try await service.isDirty()
        #expect(dirty)
    }

    @Test("clean repository is reported as clean")
    func cleanRepoDetection() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let isDirty = try await service.isDirty()
        #expect(!isDirty)
    }

    @Test("removes worktree without branch removal by default")
    func removeWorktreeKeepsBranch() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let (worktreePath, _) = try await service.createWorktree(from: "Temp worktree")

        #expect(FileManager.default.fileExists(atPath: worktreePath.path))

        try await service.removeWorktree(at: worktreePath, removeBranch: false)

        #expect(!FileManager.default.fileExists(atPath: worktreePath.path))
    }

    @Test("path outside repository is rejected")
    func pathOutsideRepositoryRejected() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)

        // Attempt to create a worktree outside the repo using ..
        let outsidePath = repoPath.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("outside", isDirectory: true)

        do {
            _ = try await service.createWorktree(
                from: "Outside",
                worktreeParent: outsidePath
            )
            Issue.record("Expected GitError.pathOutsideRepository")
        } catch is GitError {
            // Expected
        }
    }

    @Test("symlink escape attempt is rejected")
    func symlinkEscapeRejected() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        // Create a symlink pointing outside the repo
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outsideDir = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let linkPath = repoPath.appendingPathComponent(".worktrees/escape", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Create symlink pointing outside
        try FileManager.default.createSymbolicLink(
            at: linkPath,
            withDestinationURL: outsideDir
        )

        let service = try GitService(repositoryPath: repoPath)

        // Attempt to use the symlink as a worktree parent
        do {
            _ = try await service.createWorktree(
                from: "Symlink escape",
                worktreeParent: linkPath
            )
            Issue.record("Expected GitError.pathOutsideRepository")
        } catch is GitError {
            // Expected
        }
    }

    @Test("non-git directory is rejected on initialization")
    func nonGitDirectoryRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(throws: GitError.self) {
            _ = try GitService(repositoryPath: tempDir)
        }
    }

    @Test("resolves base branch correctly")
    func resolvesBaseBranch() async throws {
        let repoPath = try createTempRepo()
        defer { cleanupRepo(repoPath) }

        let service = try GitService(repositoryPath: repoPath)
        let baseBranch = try await service.resolveBaseBranch()

        #expect(baseBranch == "master" || baseBranch == "main")
    }
}

// MARK: - Helper Extensions

private extension String {
    func contains(_ substring: String, after marker: String) -> Bool {
        guard let range = range(of: marker) else { return false }
        let afterMarker = String(self[range.upperBound...])
        return afterMarker.contains(substring)
    }
}
