import Foundation
import Testing

@testable import ZeroCore

@Suite("Transcript — Restore")
@MainActor
struct TranscriptRestoreTests {
    private func makeStore() throws -> Store {
        try Store(modelContainer: nil) // in-memory
    }

    @Test("interleaved user/assistant messages, a tool call, and a plan restore in order")
    func interleavedEntriesRestoreInOrder() throws {
        let store = try makeStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/restore"
        )

        _ = try store.appendMessage(to: session, role: "user", content: "Fix the bug")
        let assistant = try store.appendMessage(to: session, role: "assistant", content: "On it.")
        let toolCall = try store.appendToolCall(
            to: assistant, id: "t1", name: "Edit", input: "input", status: "succeeded"
        )
        try store.updateToolCallEdit(toolCall, path: "/f.swift", oldText: "a", newText: "b")
        _ = try store.appendPlanSnapshot(
            to: session,
            itemsJSON: #"[{"id":"1","title":"Fix it","status":"completed"}]"#
        )
        try store.flush()

        let fetched = try #require(try store.fetchSession(id: session.id))
        let transcript = Transcript.restoring(fetched)

        #expect(transcript.entries.count == 4)
        guard case .userText(_, let userText) = transcript.entries[0] else {
            Issue.record("expected userText first")
            return
        }
        #expect(userText == "Fix the bug")

        guard case .assistantText(_, let assistantText) = transcript.entries[1] else {
            Issue.record("expected assistantText second")
            return
        }
        #expect(assistantText == "On it.")

        guard case .tool(_, let call) = transcript.entries[2] else {
            Issue.record("expected tool third")
            return
        }
        #expect(call.id == "t1")
        #expect(call.status == .succeeded)
        #expect(call.edit?.path == "/f.swift")

        guard case .plan(_, let items) = transcript.entries[3] else {
            Issue.record("expected plan fourth")
            return
        }
        #expect(items == [PlanItem(id: "1", title: "Fix it", status: .completed)])

        #expect(transcript.summary == "On it.")
        #expect(transcript.pendingPermission == nil)
    }

    @Test("an empty-content assistant row that only anchors a tool call produces no text entry")
    func emptyAnchorMessageProducesNoEntry() throws {
        let store = try makeStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/restore"
        )
        let anchor = try store.appendMessage(to: session, role: "assistant", content: "")
        _ = try store.appendToolCall(to: anchor, id: "t1", name: "Read", input: nil)
        try store.flush()

        let fetched = try #require(try store.fetchSession(id: session.id))
        let transcript = Transcript.restoring(fetched)

        #expect(transcript.entries.count == 1)
        if case .tool = transcript.entries[0] {} else {
            Issue.record("expected the only entry to be the tool call, not an empty text block")
        }
    }

    @Test("usage records fold into the same running totals a live session would show")
    func usageRecordsFold() throws {
        let store = try makeStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/restore"
        )
        _ = try store.appendUsageRecord(
            to: session, model: "haiku", inputTokens: 100, outputTokens: nil,
            cacheReadTokens: nil, cacheWriteTokens: nil, contextWindowUsed: nil, contextWindowTotal: nil
        )
        _ = try store.appendUsageRecord(
            to: session, model: nil, inputTokens: nil, outputTokens: 50,
            cacheReadTokens: nil, cacheWriteTokens: nil, contextWindowUsed: 150, contextWindowTotal: 200_000
        )
        try store.flush()

        let fetched = try #require(try store.fetchSession(id: session.id))
        let transcript = Transcript.restoring(fetched)

        // Field-wise "latest non-nil wins", replayed in order — the model from the first record
        // survives because the second never reported one.
        #expect(transcript.usage.model == "haiku")
        #expect(transcript.usage.inputTokens == 100)
        #expect(transcript.usage.outputTokens == 50)
        #expect(transcript.usage.contextWindowUsed == 150)
        #expect(transcript.usage.contextWindowTotal == 200_000)
    }

    @Test("a persisted permission request is never resurrected as pendingPermission")
    func pendingPermissionIsNeverRestored() throws {
        let store = try makeStore()
        let session = try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/restore"
        )
        _ = try store.createPermissionRequest(
            id: "p1", session: session, toolCall: nil, toolName: "Bash",
            detail: "rm -rf /tmp/x", optionsJSON: nil
        )
        try store.flush()

        let fetched = try #require(try store.fetchSession(id: session.id))
        #expect(Transcript.restoring(fetched).pendingPermission == nil)
    }

    @Test("SessionState.init(persisted:) collapses running/waitingPermission to idle, keeps the rest")
    func sessionStateFromPersisted() {
        #expect(SessionState(persisted: "idle", errorMessage: nil) == .idle)
        #expect(SessionState(persisted: "running", errorMessage: nil) == .idle)
        #expect(SessionState(persisted: "waitingPermission", errorMessage: nil) == .idle)
        #expect(SessionState(persisted: "finished", errorMessage: nil) == .finished)
        #expect(SessionState(persisted: "error", errorMessage: "boom") == .error("boom"))
        #expect(SessionState(persisted: "not-a-real-state", errorMessage: nil) == .idle)
    }

    @Test("ToolCall.Status.init(persisted:) round-trips every persisted status string")
    func toolCallStatusFromPersisted() {
        #expect(ToolCall.Status(persisted: "pending", statusDetail: nil) == .pending)
        #expect(ToolCall.Status(persisted: "running", statusDetail: nil) == .running)
        #expect(ToolCall.Status(persisted: "succeeded", statusDetail: nil) == .succeeded)
        #expect(ToolCall.Status(persisted: "failed", statusDetail: "boom") == .failed("boom"))
        #expect(ToolCall.Status(persisted: "denied", statusDetail: nil) == .denied)
        #expect(ToolCall.Status(persisted: "garbage", statusDetail: nil) == .pending)
    }
}
