import Foundation
import Testing

@testable import ZeroCore

@Suite("GitService — working tree status")
struct GitFileStatusTests {
    // MARK: - Helpers

    private func createTempRepo() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try runGit(["init"], in: tempDir)
        try runGit(["config", "user.name", "Test"], in: tempDir)
        try runGit(["config", "user.email", "test@example.com"], in: tempDir)
        try "# Test Repo\n".write(
            to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try runGit(["add", "README.md"], in: tempDir)
        try runGit(["commit", "-m", "Initial commit"], in: tempDir)
        return tempDir
    }

    @discardableResult
    private func runGit(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tests

    @Test("a clean repository reports no status")
    func cleanRepositoryHasNoStatus() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus().isEmpty)
    }

    @Test("a modified tracked file is reported as .modified")
    func modifiedFile() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "# Changed\n".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus() == ["README.md": .modified])
    }

    @Test("an untracked file is reported as .added")
    func untrackedFile() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new".write(
            to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8
        )
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus() == ["new.txt": .added])
    }

    @Test("a staged new file is reported as .added")
    func stagedNewFile() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new".write(
            to: repo.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8
        )
        try runGit(["add", "staged.txt"], in: repo)
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus() == ["staged.txt": .added])
    }

    @Test("an untracked file inside an untracked directory is listed individually")
    func untrackedFileInUntrackedDirectory() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dir = repo.appendingPathComponent("newdir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus() == ["newdir/inner.txt": .added])
    }

    @Test("a deleted tracked file has no row — nothing on disk to show one for")
    func deletedFileHasNoRow() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.removeItem(at: repo.appendingPathComponent("README.md"))
        let service = try GitService(repositoryPath: repo)

        #expect(try await service.workingTreeStatus().isEmpty)
    }

    @Test("headContent returns the committed content for a tracked file")
    func headContentForTrackedFile() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "# Changed on disk\n".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        let service = try GitService(repositoryPath: repo)

        let content = await service.headContent(ofRelativePath: "README.md")
        #expect(content == "# Test Repo\n")
    }

    @Test("headContent returns nil for a file with no version at HEAD")
    func headContentForUntrackedFile() async throws {
        let repo = try createTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new".write(
            to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8
        )
        let service = try GitService(repositoryPath: repo)

        let content = await service.headContent(ofRelativePath: "new.txt")
        #expect(content == nil)
    }

    // MARK: - rollup

    @Test("a changed file's ancestor folders roll up to the same status")
    func rollupMarksAncestors() {
        let rolled = GitFileStatus.rollup(["a/b/c.swift": .modified])
        #expect(rolled == ["a": .modified, "a/b": .modified])
    }

    @Test("modified wins over added at a shared ancestor")
    func rollupModifiedWinsOverAdded() {
        let rolled = GitFileStatus.rollup([
            "a/added.swift": .added,
            "a/modified.swift": .modified,
        ])
        #expect(rolled["a"] == .modified)
    }

    @Test("an unrelated folder is not marked")
    func rollupLeavesUnrelatedFoldersUnmarked() {
        let rolled = GitFileStatus.rollup(["a/b.swift": .modified])
        #expect(rolled["c"] == nil)
    }

    @Test("a root-level file has no folder ancestors to roll up to")
    func rollupOfRootLevelFile() {
        #expect(GitFileStatus.rollup(["README.md": .modified]).isEmpty)
    }
}
