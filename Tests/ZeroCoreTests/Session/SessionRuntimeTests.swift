import Foundation
import Testing
import SwiftData

@testable import ZeroCore

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

    @Test("creation fails with dirtyRepository error when repo has changes")
    func creationFailsOnDirtyRepo() async throws {
        let store = try createTestStore()
        let registry = ProviderRegistry()

        // Create a temporary git repo and initialize it
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir.path) }

        // Initialize a proper git repository
        let gitProcess = Process()
        gitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitProcess.arguments = ["init"]
        gitProcess.currentDirectoryURL = tempDir
        gitProcess.standardOutput = Pipe()
        gitProcess.standardError = Pipe()
        try gitProcess.run()
        gitProcess.waitUntilExit()

        // Create a test file to make repo "dirty"
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)

        let config = SessionRuntime.CreationConfig(
            repository: tempDir,
            provider: .claude,
            model: "claude-opus",
            prompt: "test"
        )

        // Expect creation to fail with dirtyRepository error
        do {
            _ = try await SessionRuntime.create(with: config, store: store, providerRegistry: registry)
            #expect(false, "Should have thrown dirtyRepository error")
        } catch SessionRuntime.CreationError.repositoryIsDirty {
            // Expected
        } catch {
            #expect(false, "Wrong error type: \(error)")
        }
    }

    // MARK: - Tool Call Persistence

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

    // MARK: - Helpers

    private func createTempDirectory() throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return tempURL
    }
}
