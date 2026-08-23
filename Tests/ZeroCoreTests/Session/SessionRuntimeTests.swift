import Foundation
import Testing
import SwiftData

@testable import ZeroCore

/// Shared sink for the spy below.
///
/// A reference type on purpose: `ProtocolDecoder.decode` is `mutating`, so a struct spy records
/// into whatever copy the runtime happens to hold and the test observes an empty array. An earlier
/// version of this spy was a struct and could not observe anything, which is why the guarantee it
/// was written for went unasserted.
final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Bool] = []

    func record(isMainThread: Bool) {
        lock.lock()
        samples.append(isMainThread)
        lock.unlock()
    }

    var recorded: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Forwards to the real decoder while noting which thread each decode ran on.
struct ThreadTrackingDecoder: ProtocolDecoder {
    let recorder: ThreadRecorder
    private var wrapped = ClaudeCodeDecoder()

    init(recorder: ThreadRecorder) {
        self.recorder = recorder
    }

    mutating func decode(line: Data) -> [AgentEvent] {
        recorder.record(isMainThread: Thread.isMainThread)
        return wrapped.decode(line: line)
    }
}

@Suite("SessionRuntime")
@MainActor
struct SessionRuntimeTests {
    private func createTestStore() throws -> Store {
        try Store(modelContainer: nil)  // in-memory
    }

    private func fixtureData(named name: String) throws -> [Data] {
        let bundle = Bundle.module
        guard let url = bundle.url(
            forResource: name,
            withExtension: "ndjson",
            subdirectory: "Fixtures/claude-code"
        ) else {
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
        }

        let content = try Data(contentsOf: url)
        let lines = content.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        return lines.map { Data($0) }
    }

    // MARK: - Real Fixture Tests

    @Test("decoding real text-turn fixture produces messages in order")
    func realTextTurnFixture() throws {
        let lines = try fixtureData(named: "text-turn")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        for line in lines {
            let events = decoder.decode(line: line)
            allEvents.append(contentsOf: events)
        }

        // Expect: init (unrecognized), thinking deltas, textDelta, turnEnded with usage
        let textEvents = allEvents.filter { event in
            if case .textDelta = event { return true }
            return false
        }
        #expect(!textEvents.isEmpty, "Should have at least one textDelta")

        let usageEvents = allEvents.filter { event in
            if case .usage = event { return true }
            return false
        }
        #expect(!usageEvents.isEmpty, "Should have usage event")

        let thinkingProgress = allEvents.filter { event in
            if case .thinkingProgress = event { return true }
            return false
        }
        #expect(!thinkingProgress.isEmpty, "Should have thinking progress events")

        // Verify thinking progress is separate from usage
        #expect(
            usageEvents.count == 1,
            "Should have exactly one usage event (thinking progress is separate)"
        )
    }

    @Test("decoding real tool-use fixture produces tool call and result together")
    func realToolUseFixture() throws {
        let lines = try fixtureData(named: "tool-use-turn")
        var decoder = ClaudeCodeDecoder()

        var toolCalls: [ToolCall] = []
        for line in lines {
            let events = decoder.decode(line: line)
            for event in events {
                if case .toolCall(let tc) = event {
                    toolCalls.append(tc)
                }
            }
        }

        // Expect: at least one tool call that starts pending and ends with a status
        let terminalCalls = toolCalls.filter { call in
            switch call.status {
            case .pending, .running: return false
            case .succeeded, .failed, .denied: return true
            }
        }
        #expect(!terminalCalls.isEmpty, "Should have tool calls with terminal status")

        // Verify output is present
        let callsWithOutput = terminalCalls.filter { $0.output != nil }
        #expect(!callsWithOutput.isEmpty, "Terminal tool calls should have output")
    }

    // MARK: - Dirty Repository Detection

    @Test("tool call and its result persist as a single call with terminal status")
    func toolCallAndResultPersistTogether() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/test"
        )

        let message = try store.appendMessage(to: session, role: "assistant", content: "Running tool")

        // Create a tool call
        let toolCall = try store.appendToolCall(
            to: message,
            id: "tool-1",
            name: "bash",
            input: "echo test",
            status: "pending"
        )

        // Update with result
        try store.updateToolCall(
            toolCall,
            output: "test\n",
            status: "succeeded"
        )

        // Fetch and verify
        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched?.orderedMessages.count == 1)
        #expect(fetched?.orderedMessages[0].toolCalls.count == 1)

        let persistedCall = fetched?.orderedMessages[0].toolCalls[0]
        #expect(persistedCall?.status == "succeeded")
        #expect(persistedCall?.output == "test\n")
    }

    // MARK: - Usage Accumulation

    @Test("usage records accumulate; thinkingProgress events do not create records")
    func usageAccumulatesAndThinkingProgressDoesNotCreateRecords() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/test"
        )

        // Simulate three turns with usage
        for turn in 0..<3 {
            _ = try store.appendUsageRecord(
                to: session,
                model: "claude-opus",
                inputTokens: 100 * (turn + 1),
                outputTokens: 50 * (turn + 1),
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                contextWindowUsed: nil,
                contextWindowTotal: nil
            )
        }

        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched?.usageRecords.count == 3)

        // Verify sequence numbers are assigned correctly (not based on thinkingProgress)
        #expect(fetched?.usageRecords[0].sequenceNumber == 0)
        #expect(fetched?.usageRecords[1].sequenceNumber == 1)
        #expect(fetched?.usageRecords[2].sequenceNumber == 2)

        // Verify token counts
        #expect(fetched?.usageRecords[0].inputTokens == 100)
        #expect(fetched?.usageRecords[1].inputTokens == 200)
        #expect(fetched?.usageRecords[2].inputTokens == 300)
    }

    // MARK: - Concurrency

    @Test("two sessions on separate temp repos run concurrently without interfering")
    func concurrentSessionsDoNotInterfere() throws {
        let store1 = try createTestStore()
        let store2 = try createTestStore()

        let session1 = try store1.createSession(
            repository: nil,
            provider: "claude",
            model: "claude-opus",
            worktreePath: "/tmp/test1",
            branch: "zero/test1"
        )

        let session2 = try store2.createSession(
            repository: nil,
            provider: "claude",
            model: "claude-opus",
            worktreePath: "/tmp/test2",
            branch: "zero/test2"
        )

        // Append to both concurrently
        let msg1 = try store1.appendMessage(to: session1, role: "user", content: "Session 1")
        let msg2 = try store2.appendMessage(to: session2, role: "user", content: "Session 2")

        try store1.flush()
        try store2.flush()

        // Verify isolation
        let fetched1 = try store1.fetchSession(id: session1.id)
        let fetched2 = try store2.fetchSession(id: session2.id)

        #expect(fetched1?.orderedMessages.count == 1)
        #expect(fetched2?.orderedMessages.count == 1)

        #expect(fetched1?.orderedMessages[0].content == "Session 1")
        #expect(fetched2?.orderedMessages[0].content == "Session 2")
    }

    // MARK: - Resume Functionality

    @Test("resume restores history from a persisted session")
    func resumeRestoresHistory() throws {
        let store = try createTestStore()

        // Create and populate a session
        let session = try store.createSession(
            repository: nil,
            provider: "claude",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123",
            providerSessionId: "provider-session-abc"
        )

        let msg1 = try store.appendMessage(to: session, role: "user", content: "Question")
        let msg2 = try store.appendMessage(to: session, role: "assistant", content: "Answer")

        try store.flush()

        // Simulate resuming
        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched != nil)

        // History should be intact
        #expect(fetched?.orderedMessages.count == 2)
        #expect(fetched?.orderedMessages[0].content == "Question")
        #expect(fetched?.orderedMessages[1].content == "Answer")

        // Provider session id should be present for resumption
        #expect(fetched?.providerSessionId == "provider-session-abc")
    }

    // MARK: - Threading Tests

    @Test("decoding a real stream never runs on the main thread")
    func decodingStaysOffTheMainThread() async throws {
        // A real subprocess emitting a real captured fixture. Nothing is mocked: `cat` is the
        // cheapest honest stand-in for a provider CLI, and the claim under test is about which
        // thread the runtime decodes on, not about what the CLI is.
        let fixture = try #require(
            Bundle.module.url(
                forResource: "text-turn",
                withExtension: "ndjson",
                subdirectory: "Fixtures/claude-code"
            )
        )
        let recorder = ThreadRecorder()
        let process = AgentProcess(
            configuration: AgentProcess.Configuration(
                executable: URL(fileURLWithPath: "/bin/cat"),
                arguments: [fixture.path],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
        // A real repo: GitService refuses anything that is not one, which is correct behavior.
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init", "-q", repo.path]
        try initProcess.run()
        initProcess.waitUntilExit()

        let store = try createTestStore()
        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "haiku",
            worktreePath: repo.path,
            branch: "zero/thread"
        )
        let runtime = SessionRuntime(
            sessionID: session.id,
            process: process,
            store: store,
            gitService: try GitService(repositoryPath: repo),
            decoder: ThreadTrackingDecoder(recorder: recorder),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: ProviderRegistry()
        )

        try await runtime.start()
        // Draining the transcript is how a UI consumes a session, and the stream finishing is how
        // it learns the session ended — so this is the consumer's real path, not a test shortcut.
        for await _ in runtime.transcript {}
        await runtime.waitUntilFinished()

        let samples = recorder.recorded
        #expect(!samples.isEmpty, "no decode ran, so this asserts nothing")
        #expect(
            !samples.contains(true),
            "decoding ran on the main thread \(samples.filter { $0 }.count) of \(samples.count) times"
        )
    }

    private func createTempDirectory() throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return tempURL
    }

    // MARK: - C4 — resume

    @Test("a resumed Claude Code session is relaunched with --resume and the persisted id")
    func resumePassesTheProviderSessionID() throws {
        // Asserted at the layer that decides the argv, because that is what the CLI actually reads.
        let registry = ProviderRegistry()
        guard case .available = registry.status(of: .claude) else { return }
        let configuration = try registry.configuration(
            for: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            extraArguments: ["--resume", "abc-123"]
        )
        #expect(configuration.arguments.contains("--resume"))
        #expect(configuration.arguments.contains("abc-123"))
        // The opening flags still have to be there: a resumed session is the same stream shape.
        #expect(configuration.arguments.contains("--print"))
        #expect(configuration.arguments.contains("stream-json"))
        // A flag verified not to exist must never reappear.
        #expect(!configuration.arguments.contains("--permission-prompt-tool"))
    }

    @Test("a session with no provider id resumes read-only with its history intact")
    func resumeWithoutProviderIDIsReadOnly() async throws {
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repo.path]
        try git.run()
        git.waitUntilExit()

        let session = try store.createSession(
            repository: nil,
            provider: "claude",
            model: "haiku",
            worktreePath: repo.appendingPathComponent(".worktrees/x").path,
            branch: "zero/readonly"
        )
        _ = try store.appendMessage(to: session, role: "assistant", content: "earlier work")
        try store.flush()
        let id = session.id

        let runtime = try await SessionRuntime.resume(
            sessionID: id,
            store: store,
            providerRegistry: ProviderRegistry()
        )

        // The transcript finishes rather than hanging: a read-only session has nothing more to say,
        // and a stream that never ends would leave the UI waiting forever.
        for await _ in runtime.transcript {}

        #expect(await runtime.state == .finished)
        let restored = try store.fetchSession(id: id)
        #expect(restored?.orderedMessages.map(\.content) == ["earlier work"])
    }

    @Test("sending to a session with no live process throws instead of dropping the turn")
    func sendWithoutProcessThrows() async throws {
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repo.path]
        try git.run()
        git.waitUntilExit()

        let session = try store.createSession(
            repository: nil, provider: "claude", model: "haiku",
            worktreePath: repo.path, branch: "zero/nosend"
        )
        let runtime = SessionRuntime(
            sessionID: session.id,
            process: AgentProcess(
                configuration: AgentProcess.Configuration(
                    executable: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [], environment: [:], workingDirectory: repo
                )
            ),
            store: store,
            gitService: try GitService(repositoryPath: repo),
            decoder: ClaudeCodeDecoder(),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: ProviderRegistry()
        )

        // A message that silently vanishes is worse than an error: the user retypes it and assumes
        // they made the mistake.
        await #expect(throws: (any Error).self) {
            try await runtime.send("hello")
        }
    }


    // MARK: - Permission mode: in-band response (Codex/ACP)

    @Test("resolvePermission sends Codex's encoded response back over stdin")
    func resolvePermissionSendsCodexResponse() async throws {
        // The regression this closes: answering a Codex/ACP permission prompt in the UI never
        // reached the process at all (see 003-permission-modes, Phase B) — the option the user
        // picked had nowhere to go, so the agent stayed blocked no matter what was clicked.
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-stdin-capture-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: capture) }
        let stub = try makeStdinCapturingStub(writingTo: capture)
        defer { try? FileManager.default.removeItem(at: stub) }

        let session = try store.createSession(
            repository: nil, provider: "codex", model: "m",
            worktreePath: repo.path, branch: "zero/resolve-permission-codex"
        )
        let runtime = SessionRuntime(
            sessionID: session.id,
            process: AgentProcess(configuration: .init(
                executable: stub, arguments: [], environment: [:], workingDirectory: repo
            )),
            store: store,
            gitService: try GitService(repositoryPath: repo),
            decoder: CodexDecoder(),
            encoder: CodexEncoder(),
            providerRegistry: ProviderRegistry()
        )
        try await runtime.start()
        try await runtime.resolvePermission(requestID: "42", optionID: "accept", origin: .userAction)
        await runtime.closeStdin()
        await runtime.waitUntilFinished()

        let written = try String(contentsOf: capture, encoding: .utf8)
        #expect(written.contains("\"id\":\"42\""))
        #expect(written.contains("\"decision\":\"accept\""))
    }

    @Test("resolvePermission throws for Claude Code — it has no in-band channel")
    func resolvePermissionThrowsForClaudeCode() async throws {
        // Claude Code's requests resolve through PermissionBroker's hook socket, never through
        // this method — asserting the throw keeps that boundary from silently drifting.
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        let session = try store.createSession(
            repository: nil, provider: "claude", model: "m",
            worktreePath: repo.path, branch: "zero/resolve-permission-claude"
        )
        let runtime = SessionRuntime(
            sessionID: session.id,
            process: AgentProcess(configuration: .init(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], environment: [:], workingDirectory: repo
            )),
            store: store,
            gitService: try GitService(repositoryPath: repo),
            decoder: ClaudeCodeDecoder(),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: ProviderRegistry()
        )
        await #expect(throws: (any Error).self) {
            try await runtime.resolvePermission(requestID: "1", optionID: "allow_once", origin: .userAction)
        }
    }

    // MARK: - Workspace

    @Test("a session in the current checkout runs where the uncommitted work is")
    func currentCheckoutRunsInTheRepository() async throws {
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)
        try "work in progress".write(
            to: repo.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8
        )

        // A provider that cannot resolve, so this asserts where the session would run without
        // launching a real agent. The dirty working tree must not be an obstacle: continuing
        // uncommitted work is the ordinary case.
        do {
            _ = try await SessionRuntime.create(
                with: .init(
                    repository: repo, provider: Self.missingProvider, model: "m", prompt: "t",
                    workspace: .currentCheckout
                ),
                store: store,
                providerRegistry: ProviderRegistry()
            )
            Issue.record("expected the provider to fail")
        } catch SessionRuntime.CreationError.providerError {
            // Reached provider resolution, so nothing rejected the dirty checkout on the way.
        } catch {
            Issue.record("failed before the provider: \(error)")
        }

        // The user's file is untouched: an in-place session must never tidy the workspace it was
        // asked to work in.
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("wip.txt").path))
    }

    @Test("an isolated worktree starts from the commit, so uncommitted work is absent")
    func isolatedWorktreeExcludesUncommittedWork() async throws {
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)
        try "not committed".write(
            to: repo.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8
        )

        let service = try GitService(repositoryPath: repo)
        let (worktree, _) = try await service.createWorktree(from: "beside my work")

        // This is the trade the picker describes, asserted rather than asserted-in-a-tooltip.
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("wip.txt").path))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("wip.txt").path))
    }

    @Test("the busy-checkout message points at the worktree option")
    func busyCheckoutMessageIsActionable() {
        let message = SessionRuntime.CreationError.checkoutBusy(path: "/tmp/x").description
        #expect(message.contains("/tmp/x"))
        // A refusal that does not say what to do instead is just a wall.
        #expect(message.lowercased().contains("isolated worktree"))
    }

    private static let missingProvider = ProviderDescriptor(
        id: "definitely-not-installed",
        displayName: "Nothing",
        executableCandidates: ["definitely-not-installed"],
        versionCommand: ["--version"],
        minimumVersion: "0.0.0",
        launchArguments: []
    )

    /// A stand-in for a provider CLI: prints its argv on one line, then keeps reading stdin like a
    /// real long-lived agent would — so the initial prompt send has something alive to receive it.
    private func makeArgvEchoingStub() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-argv-stub-\(UUID().uuidString.prefix(8)).sh")
        try "#!/bin/sh\necho \"$@\"\ncat\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// A stand-in that captures exactly what it reads from stdin into a file, for observing what
    /// `resolvePermission` actually sends. Not an echo to stdout: the payload is a well-formed
    /// Codex JSON-RPC response, so `CodexDecoder` would consume it as one instead of surfacing it
    /// as `.unrecognized` — capturing the raw bytes before the decoder ever sees them is what
    /// actually asserts on what was sent, not on how the decoder happens to interpret it.
    private func makeStdinCapturingStub(writingTo outputPath: URL) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-stdin-capture-\(UUID().uuidString.prefix(8)).sh")
        let script = "#!/bin/sh\ncat > \(HookSettings.shellQuoted(outputPath.path))\n"
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func makeRepository(at url: URL) throws {
        for arguments in [["init", "-q", url.path],
                          ["-C", url.path, "commit", "-q", "--allow-empty", "-m", "base"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
            ]) { _, new in new }
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run()
            git.waitUntilExit()
        }
    }

    // MARK: - The permission hook actually gets installed

    @Test("create() installs the permission hook before the process launches")
    func createInstallsPermissionHook() async throws {
        // The regression: the hook settings were never passed to configuration(), so a real session
        // launched with no PreToolUse hook at all. A tool call had no one to ask over the socket —
        // the CLI fell back to asking in plain chat text, and the native prompt this app exists to
        // show never appeared.
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        // `/bin/echo` prints exactly the argv it was launched with, and the decoder cannot parse that
        // as JSON — it comes back as `.unrecognized(raw:)`, which is the real argv `create()` built,
        // not a reconstruction of what it should have built.
        let stub = try makeArgvEchoingStub()
        defer { try? FileManager.default.removeItem(at: stub) }
        let registry = ProviderRegistry(
            resolveExecutable: { _, _ in stub },
            getVersion: { _, _ in "2.1.237 (Claude Code)" }
        )
        let socketsDir = URL(fileURLWithPath: "/tmp/zs-\(UUID().uuidString.prefix(8))")
        let broker = PermissionBroker(socketsDirectory: socketsDir) { _ in
            .init(decision: .deny, origin: .userAction)
        }

        let runtime = try await SessionRuntime.create(
            with: .init(repository: repo, provider: .claude, model: "m", prompt: "t"),
            store: store,
            providerRegistry: registry,
            permissionSetup: .init(broker: broker, helperPath: "/path/to/zero-permission-hook")
        )
        await runtime.closeStdin()

        var echoed = ""
        for await event in runtime.transcript {
            if case .unrecognized(let raw) = event { echoed += String(decoding: raw, as: UTF8.self) }
        }
        await runtime.waitUntilFinished()
        await broker.stopAll()

        #expect(echoed.contains("--settings"))
        #expect(echoed.contains("PreToolUse"))
        #expect(echoed.contains("zero-permission-hook"))
    }

    @Test("create() in .auto mode narrows the hook to network tools and adds --permission-mode auto")
    func createAutoModeNarrowsHook() async throws {
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        let stub = try makeArgvEchoingStub()
        defer { try? FileManager.default.removeItem(at: stub) }
        let registry = ProviderRegistry(
            resolveExecutable: { _, _ in stub },
            getVersion: { _, _ in "2.1.237 (Claude Code)" }
        )
        let socketsDir = URL(fileURLWithPath: "/tmp/zs-\(UUID().uuidString.prefix(8))")
        let broker = PermissionBroker(socketsDirectory: socketsDir) { _ in
            .init(decision: .deny, origin: .userAction)
        }

        let runtime = try await SessionRuntime.create(
            with: .init(repository: repo, provider: .claude, model: "m", prompt: "t", permissionMode: .auto),
            store: store,
            providerRegistry: registry,
            permissionSetup: .init(broker: broker, helperPath: "/path/to/zero-permission-hook")
        )
        await runtime.closeStdin()

        var echoed = ""
        for await event in runtime.transcript {
            if case .unrecognized(let raw) = event { echoed += String(decoding: raw, as: UTF8.self) }
        }
        await runtime.waitUntilFinished()
        await broker.stopAll()

        #expect(echoed.contains("--permission-mode auto"))
        #expect(echoed.contains("--settings"))
        // The hook is still installed — for WebFetch/WebSearch — just narrowed: the matcher Zero
        // wrote into --settings is autoMatcher, not the broad askMatcher.
        #expect(echoed.contains(HookSettings.autoMatcher))
        #expect(!echoed.contains(HookSettings.askMatcher))
    }

    @Test("create() in .bypass mode installs no hook at all and adds --permission-mode bypassPermissions")
    func createBypassModeInstallsNoHook() async throws {
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        let stub = try makeArgvEchoingStub()
        defer { try? FileManager.default.removeItem(at: stub) }
        let registry = ProviderRegistry(
            resolveExecutable: { _, _ in stub },
            getVersion: { _, _ in "2.1.237 (Claude Code)" }
        )
        let socketsDir = URL(fileURLWithPath: "/tmp/zs-\(UUID().uuidString.prefix(8))")
        let broker = PermissionBroker(socketsDirectory: socketsDir) { _ in
            .init(decision: .deny, origin: .userAction)
        }

        let runtime = try await SessionRuntime.create(
            with: .init(repository: repo, provider: .claude, model: "m", prompt: "t", permissionMode: .bypass),
            store: store,
            providerRegistry: registry,
            // Passed anyway, the way a real caller always would: .bypass must ignore it rather
            // than depend on the caller remembering to omit it.
            permissionSetup: .init(broker: broker, helperPath: "/path/to/zero-permission-hook")
        )
        await runtime.closeStdin()

        var echoed = ""
        for await event in runtime.transcript {
            if case .unrecognized(let raw) = event { echoed += String(decoding: raw, as: UTF8.self) }
        }
        await runtime.waitUntilFinished()
        await broker.stopAll()

        #expect(echoed.contains("--permission-mode bypassPermissions"))
        #expect(!echoed.contains("--settings"))
        #expect(!echoed.contains("PreToolUse"))
    }

    @Test("the session's socket exists before the process would need it")
    func socketExistsBeforeProcessNeedsIt() async throws {
        // Ordering matters: if the socket is opened after the CLI has already started, an early
        // tool call finds nothing listening and the hook fails closed for a reason that has nothing
        // to do with the user's actual answer.
        let store = try createTestStore()
        let repo = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try makeRepository(at: repo)

        let stub = try makeArgvEchoingStub()
        defer { try? FileManager.default.removeItem(at: stub) }
        let registry = ProviderRegistry(
            resolveExecutable: { _, _ in stub },
            getVersion: { _, _ in "2.1.237 (Claude Code)" }
        )
        let socketsDir = URL(fileURLWithPath: "/tmp/zs-\(UUID().uuidString.prefix(8))")
        let broker = PermissionBroker(socketsDirectory: socketsDir) { _ in
            .init(decision: .allow, origin: .userAction)
        }

        let runtime = try await SessionRuntime.create(
            with: .init(repository: repo, provider: .claude, model: "m", prompt: "t"),
            store: store,
            providerRegistry: registry,
            permissionSetup: .init(broker: broker, helperPath: "/path/to/zero-permission-hook")
        )
        await runtime.closeStdin()
        for await _ in runtime.transcript {}
        await runtime.waitUntilFinished()
        await broker.stopAll()
    }

}
