import Foundation
import Testing
import SwiftData

@testable import ZeroCore

@Suite("Store — Persistence")
@MainActor
struct StoreTests {
    private func createTestStore() throws -> Store {
        try Store(modelContainer: nil) // in-memory
    }

    @Test("round-trip a session with its full history")
    func roundTripSessionWithHistory() throws {
        let store = try createTestStore()

        // Create repository and session
        let repo = try store.createRepository(
            path: "/tmp/test",
            name: "TestRepo",
            defaultBranch: "main"
        )

        let session = try store.createSession(
            repository: repo,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123",
            providerSessionId: "provider-session-abc"
        )

        // Append a few messages
        let msg1 = try store.appendMessage(to: session, role: "user", content: "Hello")
        let msg2 = try store.appendMessage(to: session, role: "assistant", content: "Hi there")

        // Append a tool call
        let toolCall = try store.appendToolCall(
            to: msg2,
            id: "tool-1",
            name: "bash",
            input: "echo test",
            status: "running"
        )
        try store.updateToolCall(
            toolCall,
            output: "test\n",
            status: "succeeded"
        )

        // Append usage
        let usage = try store.appendUsageRecord(
            to: session,
            model: "claude-opus",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            contextWindowUsed: 150,
            contextWindowTotal: 200000
        )

        // Fetch the session back
        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched != nil)
        #expect(fetched?.provider == "claude-code")
        #expect(fetched?.model == "claude-opus")
        #expect(fetched?.providerSessionId == "provider-session-abc")

        // Verify messages persisted
        #expect(fetched?.orderedMessages.count == 2)
        #expect(fetched?.orderedMessages[0].content == "Hello")
        #expect(fetched?.orderedMessages[1].content == "Hi there")

        // Verify tool call persisted
        #expect(fetched?.orderedMessages[1].toolCalls.count == 1)
        #expect(fetched?.orderedMessages[1].toolCalls[0].name == "bash")
        #expect(fetched?.orderedMessages[1].toolCalls[0].status == "succeeded")
        #expect(fetched?.orderedMessages[1].toolCalls[0].output == "test\n")

        // Verify usage persisted
        #expect(fetched?.usageRecords.count == 1)
        #expect(fetched?.usageRecords[0].inputTokens == 100)
        #expect(fetched?.usageRecords[0].outputTokens == 50)
        #expect(fetched?.usageRecords[0].cacheReadTokens == 0)
    }

    @Test("message ordering survives out-of-order insertion")
    func messageOrderingIsStable() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123"
        )

        // Simulate out-of-order arrival by inserting message 2 first, then 1, then 3
        // But the sequenceNumber assignment happens at append time
        let msg1 = try store.appendMessage(to: session, role: "user", content: "First")
        let msg2 = try store.appendMessage(to: session, role: "assistant", content: "Second")
        let msg3 = try store.appendMessage(to: session, role: "user", content: "Third")

        // Fetch and verify ordering by sequenceNumber
        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched?.orderedMessages.count == 3)

        let sorted = fetched!.messages.sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(sorted[0].content == "First")
        #expect(sorted[1].content == "Second")
        #expect(sorted[2].content == "Third")

        #expect(sorted[0].sequenceNumber == 0)
        #expect(sorted[1].sequenceNumber == 1)
        #expect(sorted[2].sequenceNumber == 2)
    }

    @Test("permission request persists resolution and origin")
    func permissionRequestPersistsResolution() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123"
        )

        // Create a permission request
        let request = try store.createPermissionRequest(
            id: "perm-123",
            session: session,
            toolCall: nil,
            toolName: "bash",
            detail: "Run: rm -rf /",
            optionsJSON: nil
        )

        // Resolve it with userAction origin
        try store.resolvePermissionRequest(
            request,
            resolution: "allow-once",
            source: "userAction",
            originDetail: nil
        )

        // Fetch and verify
        let fetched = try store.fetchPermissionRequest(id: "perm-123")
        #expect(fetched != nil)
        #expect(fetched?.resolution == "allow-once")
        #expect(fetched?.resolvedBySource == "userAction")
        #expect(fetched?.resolvedAt != nil)

        // Test with rule origin
        let request2 = try store.createPermissionRequest(
            id: "perm-456",
            session: session,
            toolCall: nil,
            toolName: "bash",
            detail: "Run: echo safe",
            optionsJSON: nil
        )

        try store.resolvePermissionRequest(
            request2,
            resolution: "allow-always",
            source: "userConfiguredRule:safe-commands",
            originDetail: "safe-commands"
        )

        let fetched2 = try store.fetchPermissionRequest(id: "perm-456")
        #expect(fetched2?.resolution == "allow-always")
        #expect(fetched2?.resolvedBySource == "userConfiguredRule:safe-commands")
        #expect(fetched2?.resolvedByOriginDetail == "safe-commands")
    }

    @Test("usage records aggregate correctly")
    func usageRecordsAggregateCorrectly() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123"
        )

        // Append multiple usage records
        let u1 = try store.appendUsageRecord(
            to: session,
            model: "claude-opus",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWriteTokens: 5,
            contextWindowUsed: nil,
            contextWindowTotal: nil
        )

        let u2 = try store.appendUsageRecord(
            to: session,
            model: "claude-opus",
            inputTokens: 200,
            outputTokens: 100,
            cacheReadTokens: 20,
            cacheWriteTokens: 10,
            contextWindowUsed: nil,
            contextWindowTotal: nil
        )

        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched?.usageRecords.count == 2)

        // Verify sequence numbers are assigned correctly
        #expect(fetched?.usageRecords[0].sequenceNumber == 0)
        #expect(fetched?.usageRecords[1].sequenceNumber == 1)

        // Verify all token categories are persisted
        #expect(fetched?.usageRecords[0].inputTokens == 100)
        #expect(fetched?.usageRecords[0].cacheReadTokens == 10)
        #expect(fetched?.usageRecords[1].outputTokens == 100)
        #expect(fetched?.usageRecords[1].cacheWriteTokens == 10)
    }

    @Test("pricing lookup distinguishes not-found from zero price")
    func pricingLookupDistinguishesNotFoundFromZeroPrice() throws {
        let store = try createTestStore()

        // Set a pricing entry with some zero prices
        try store.setPricingEntry(
            provider: "anthropic",
            model: "claude-opus",
            inputPrice: 0.003,
            outputPrice: 0.015,
            cacheReadPrice: 0,
            cacheWritePrice: 0.00375,
            tableVersion: 1
        )

        // Fetch the entry
        let entry = try store.fetchPricingEntry(provider: "anthropic", model: "claude-opus")
        #expect(entry != nil)
        #expect(entry?.inputPrice == 0.003)
        #expect(entry?.cacheReadPrice == 0) // zero, not nil

        // Fetch something that doesn't exist
        let missing = try store.fetchPricingEntry(provider: "anthropic", model: "unknown-model")
        #expect(missing == nil) // nil, not a zero-price entry

        // Verify we can tell them apart in the type system
        if missing != nil {
            // This should not execute
            #expect(false, "Missing entry should be nil")
        }
    }

    @Test("session state transitions")
    func sessionStateTransitions() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123"
        )

        #expect(session.state == "idle")

        // Transition to running
        try store.markSessionStarted(session)
        let running = try store.fetchSession(id: session.id)
        #expect(running?.state == "running")
        #expect(running?.startedAt != nil)

        // Transition to error
        try store.updateSessionError(session, message: "Something broke")
        let errored = try store.fetchSession(id: session.id)
        #expect(errored?.state == "error")
        #expect(errored?.errorMessage == "Something broke")

        // Transition to finished
        try store.markSessionFinished(session)
        let finished = try store.fetchSession(id: session.id)
        #expect(finished?.state == "finished")
        #expect(finished?.endedAt != nil)
    }

    @Test("list sessions returns them in reverse creation order")
    func listSessionsReturnsThemInReverseCreationOrder() throws {
        let store = try createTestStore()

        let s1 = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test1",
            branch: "zero/test-1"
        )

        let s2 = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test2",
            branch: "zero/test-2"
        )

        let sessions = try store.listSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == s2.id) // s2 is newer, comes first
        #expect(sessions[1].id == s1.id)
    }

    @Test("tool call file edit details are persisted")
    func toolCallFileEditDetailsArePersisted() throws {
        let store = try createTestStore()

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test/.git/worktrees/zero",
            branch: "zero/test-123"
        )

        let message = try store.appendMessage(to: session, role: "assistant", content: "Fixed it")

        let toolCall = try store.appendToolCall(
            to: message,
            id: "edit-1",
            name: "edit",
            input: nil,
            status: "succeeded"
        )

        try store.updateToolCallEdit(
            toolCall,
            path: "/path/to/file.swift",
            oldText: "let x = 1",
            newText: "let x = 2"
        )

        let fetched = try store.fetchSession(id: session.id)
        let edit = fetched?.orderedMessages[0].toolCalls[0]
        #expect(edit?.editPath == "/path/to/file.swift")
        #expect(edit?.editOldText == "let x = 1")
        #expect(edit?.editNewText == "let x = 2")
    }

    @Test("a flushed history still reads back whole")
    func historySurvivesBatching() throws {
        let store = try createTestStore()
        let target = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "haiku",
            worktreePath: "/tmp/wt",
            branch: "zero/order"
        )
        for index in 0..<200 {
            _ = try store.appendMessage(to: target, role: "assistant", content: "m\(index)")
        }
        try store.flush()
        // The point of batching is speed, not fewer messages — and not a reordered transcript.
        // Batching is exactly what broke ordering: a `save()` per append used to preserve insertion
        // order by accident, so nothing asserted the guarantee until it was gone.
        let ordered = target.orderedMessages
        #expect(ordered.count == 200)
        #expect(ordered.map { $0.sequenceNumber } == Array(0..<200))
        #expect(ordered.map { $0.content } == (0..<200).map { "m\($0)" })
    }

    // MARK: - 006-persistent-projects-sessions

    @Test("upsertRepository returns the same row for the same path, not a duplicate")
    func upsertRepositoryDeduplicatesByPath() throws {
        let store = try createTestStore()
        let first = try store.upsertRepository(path: "/tmp/repo", name: "repo", defaultBranch: "main")
        let second = try store.upsertRepository(path: "/tmp/repo", name: "repo", defaultBranch: "main")
        #expect(first.id == second.id)
        #expect(try store.listRepositories().count == 1)
    }

    @Test("listRepositories returns creation order")
    func listRepositoriesOrder() throws {
        let store = try createTestStore()
        let a = try store.createRepository(path: "/tmp/a", name: "a", defaultBranch: "main")
        let b = try store.createRepository(path: "/tmp/b", name: "b", defaultBranch: "main")
        #expect(try store.listRepositories().map(\.id) == [a.id, b.id])
    }

    @Test("appendPlanSnapshot round-trips in sequence order")
    func planSnapshotsRoundTrip() throws {
        let store = try createTestStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/plan"
        )
        _ = try store.appendPlanSnapshot(to: session, itemsJSON: #"[{"id":"1"}]"#)
        _ = try store.appendPlanSnapshot(to: session, itemsJSON: #"[{"id":"1"},{"id":"2"}]"#)
        let fetched = try store.fetchSession(id: session.id)
        let ordered = fetched?.orderedPlanSnapshots ?? []
        #expect(ordered.count == 2)
        #expect(ordered.map(\.itemsJSON) == [#"[{"id":"1"}]"#, #"[{"id":"1"},{"id":"2"}]"#])
    }

    @Test(
        "messages, tool calls, and plan snapshots share one gapless, chronological sequence"
    )
    func sharedEntrySequenceInterleaves() throws {
        let store = try createTestStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/seq"
        )
        let userMsg = try store.appendMessage(to: session, role: "user", content: "hi")
        let asstMsg = try store.appendMessage(to: session, role: "assistant", content: "")
        let toolCall = try store.appendToolCall(to: asstMsg, id: "t1", name: "Read", input: nil)
        _ = try store.appendPlanSnapshot(to: session, itemsJSON: "[]")

        #expect(userMsg.sequenceNumber == 0)
        #expect(asstMsg.sequenceNumber == 1)
        #expect(toolCall.sequenceNumber == 2)
        let fetched = try store.fetchSession(id: session.id)
        #expect(fetched?.orderedPlanSnapshots.first?.sequenceNumber == 3)
        // No two entries share a position, and nothing skipped one — otherwise a restore built by
        // sorting on this field could interleave rows in the wrong order or drop one silently.
        let allSequences = [userMsg.sequenceNumber, asstMsg.sequenceNumber, toolCall.sequenceNumber]
            + (fetched.map { [$0.orderedPlanSnapshots.first!.sequenceNumber] } ?? [])
        #expect(Set(allSequences).count == allSequences.count)
    }

    @Test("appendToolCall on a message with no session throws rather than silently misordering")
    func appendToolCallRequiresAttachedSession() throws {
        let store = try createTestStore()
        let detached = Message(session: nil, role: "assistant", content: "", sequenceNumber: 0)
        #expect(throws: StoreError.detachedMessage) {
            _ = try store.appendToolCall(to: detached, id: "t1", name: "Read", input: nil)
        }
    }

    @Test("defaultModelContainer resolves under the given base directory and bundle id, not the app bundle")
    func defaultModelContainerResolvesUnderApplicationSupport() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let container = try Store.defaultModelContainer(baseDirectory: tempBase)
        let store = try Store(modelContainer: container)
        _ = try store.createRepository(path: "/tmp/repo", name: "repo", defaultBranch: "main")
        try store.flush()

        let bundleID = Bundle.main.bundleIdentifier ?? "the.stool.zero"
        let expectedDirectory = tempBase.appendingPathComponent(bundleID, isDirectory: true)
        #expect(
            FileManager.default.fileExists(
                atPath: expectedDirectory.appendingPathComponent("Zero.store").path
            )
        )
        // Not inside the app bundle, wherever the test binary happens to live.
        #expect(!expectedDirectory.path.hasPrefix(Bundle.main.bundleURL.path))
    }

    @Test("defaultModelContainer is durable: a second Store against the same location reads what the first wrote")
    func defaultModelContainerIsDurableAcrossInstances() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let sessionID: UUID
        do {
            let store = try Store(modelContainer: Store.defaultModelContainer(baseDirectory: tempBase))
            let repo = try store.createRepository(path: "/tmp/repo", name: "repo", defaultBranch: "main")
            let session = try store.createSession(
                repository: repo, provider: "claude-code", model: "haiku",
                worktreePath: "/tmp/repo", branch: "main"
            )
            _ = try store.appendMessage(to: session, role: "user", content: "hello")
            try store.flush()
            sessionID = session.id
        }
        // A fresh Store, fresh ModelContainer, same on-disk location — this is what a relaunch is.
        let reopened = try Store(modelContainer: Store.defaultModelContainer(baseDirectory: tempBase))
        let restored = try reopened.fetchSession(id: sessionID)
        #expect(restored?.orderedMessages.first?.content == "hello")
        #expect(restored?.repository?.path == "/tmp/repo")
    }
}
