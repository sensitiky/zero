import Foundation
import Testing

@testable import ZeroCore

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    private let tempDir = FileManager.default.temporaryDirectory

    @Test("absent binary reports not-installed")
    func absentBinaryReportsNotInstalled() {
        let descriptor = ProviderDescriptor(
            id: "missing",
            displayName: "Missing Provider",
            executableCandidates: ["missing-provider-that-does-not-exist"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in nil }
        )

        let status = registry.status(of: descriptor)
        guard case .notInstalled = status else {
            Issue.record("Expected notInstalled status, got \(status)")
            return
        }
    }

    @Test("present binary reports available with version")
    func presentBinaryReportsAvailable() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "2.0.0" }
        )

        let status = registry.status(of: descriptor)
        guard case .available(let version) = status else {
            Issue.record("Expected available status, got \(status)")
            return
        }
        #expect(version == "2.0.0")
    }

    @Test("version too old is reported")
    func versionTooOldReported() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "2.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "1.5.0" }
        )

        let status = registry.status(of: descriptor)
        guard case .versionTooOld(let installed, let minimum, _) = status else {
            Issue.record("Expected versionTooOld status, got \(status)")
            return
        }
        #expect(installed == "1.5.0")
        #expect(minimum == "2.0.0")
    }

    @Test("version parsing handles major.minor.patch")
    func versionParsingHandles3Part() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.2.3",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "1.2.4" }
        )

        let status = registry.status(of: descriptor)
        guard case .available = status else {
            Issue.record("Expected available status, got \(status)")
            return
        }
    }

    @Test("resolved path is absolute")
    func resolvedPathIsAbsolute() throws {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        // Use an injected resolver that returns an absolute path.
        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") }
        )

        // Check it resolves to an absolute path.
        let resolvedPath = try registry.configuration(
            for: descriptor,
            workingDirectory: tempDir
        ).executable.path

        #expect(resolvedPath.hasPrefix("/"))
    }

    @Test("non-executable file is rejected")
    func nonExecutableFileRejected() {
        let tempFile = tempDir.appendingPathComponent("not-executable")

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? "not executable".write(toFile: tempFile.path, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["not-executable"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(candidateDirectories: [tempDir])

        let status = registry.status(of: descriptor)
        guard case .notInstalled = status else {
            Issue.record("Expected notInstalled status, got \(status)")
            return
        }
    }

    @Test("version parsing handles major.minor")
    func versionParsingHandles2Part() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.2.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "1.2" }
        )

        let status = registry.status(of: descriptor)
        guard case .available = status else {
            Issue.record("Expected available status, got \(status)")
            return
        }
    }

    @Test("candidate directory is probed in order")
    func candidateDirectoryProbedInOrder() throws {
        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")

        try? FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        let binary1 = dir1.appendingPathComponent("test")
        let binary2 = dir2.appendingPathComponent("test")

        try? "#!/bin/sh\necho 1.0.0\n".write(toFile: binary1.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary1.path)

        try? "#!/bin/sh\necho 2.0.0\n".write(toFile: binary2.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary2.path)

        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(candidateDirectories: [dir1, dir2])

        // Should find the first one.
        let config = try registry.configuration(
            for: descriptor,
            workingDirectory: tempDir
        )
        #expect(config.executable == binary1)
    }

    @Test("authentication failure is reported")
    func authenticationFailureReported() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: [],
            requiresAuthentication: true,
            checkAuthentication: { throw NSError(domain: "test", code: 1) }
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "1.0.0" }
        )

        let status = registry.status(of: descriptor)
        guard case .resolutionFailed = status else {
            Issue.record("Expected resolutionFailed status, got \(status)")
            return
        }
    }

    @Test("not authenticated is reported")
    func notAuthenticatedReported() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: [],
            requiresAuthentication: true,
            checkAuthentication: { "API key not configured" }
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in "1.0.0" }
        )

        let status = registry.status(of: descriptor)
        guard case .notAuthenticated(let reason) = status else {
            Issue.record("Expected notAuthenticated status, got \(status)")
            return
        }
        #expect(reason == "API key not configured")
    }

    @Test("unparseable version is reported")
    func unparseableVersionReported() {
        let descriptor = ProviderDescriptor(
            id: "test",
            displayName: "Test Provider",
            executableCandidates: ["test"],
            versionCommand: ["--version"],
            minimumVersion: "1.0.0",
            launchArguments: []
        )

        let registry = ProviderRegistry(
            candidateDirectories: [tempDir],
            resolveExecutable: { _, _ in URL(fileURLWithPath: "/usr/bin/test") },
            getVersion: { _, _ in nil }
        )

        let status = registry.status(of: descriptor)
        guard case .resolutionFailed = status else {
            Issue.record("Expected resolutionFailed status, got \(status)")
            return
        }
    }

    // Regression coverage for bug 012-codex-version-check-fails: `codex version` requires a TTY
    // and fails with empty stdout on real Codex CLI installs (verified against `codex-cli
    // 0.150.1`); `codex --version` is the correct, non-interactive-safe flag. This fake script
    // mimics that exact real-world shape so the test doesn't depend on Codex being installed.
    @Test("codex descriptor's version command resolves against the real Codex CLI's shape")
    func codexVersionCommandResolvesAgainstRealCLIShape() throws {
        let scriptDir = tempDir.appendingPathComponent("codex-repro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptDir) }

        let fakeCodex = scriptDir.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            echo "codex-cli 0.150.1"
            exit 0
        fi
        echo "Error: stdin is not a terminal" >&2
        exit 1
        """
        try script.write(toFile: fakeCodex.path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCodex.path
        )

        let registry = ProviderRegistry(candidateDirectories: [scriptDir])

        let status = registry.status(of: ProviderDescriptor.codex)
        guard case .available(let version) = status else {
            Issue.record(
                "Expected available status using the real Codex CLI's --version shape, got \(status)"
            )
            return
        }
        #expect(version == "codex-cli 0.150.1")
    }

    @Test("codex descriptor pins the corrected version command")
    func codexDescriptorPinsCorrectedVersionCommand() {
        #expect(ProviderDescriptor.codex.versionCommand == ["--version"])
    }
}
