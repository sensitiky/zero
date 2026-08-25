import Foundation
import Testing
import ZeroCore

@testable import ZeroBridge

/// FR-22 and FR-23: one normalized `AgentEvent` in, one frame out — or nothing, on purpose.
///
/// Every event is driven through a real `Transcript` first, so `affectedEntry` is tested against the
/// assembly rules it mirrors rather than against a hand-built array that could drift from what
/// production ever produces.
@Suite("AgentEventMapping")
struct AgentEventMappingTests {
    private let sessionId = "8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0"

    /// Applies the events to a transcript and returns the frame the last one produced.
    private func frame(after events: [AgentEvent]) -> BridgeEvent? {
        var transcript = Transcript()
        for event in events.dropLast() { transcript.apply(event) }
        guard let last = events.last else { return nil }
        transcript.apply(last)
        return Projection.bridgeEvent(for: last, sessionId: sessionId, transcript: transcript)
    }

    private func json(_ event: BridgeEvent) throws -> String {
        try #require(String(data: try BridgeJSON.encode(event), encoding: .utf8))
    }

    // MARK: - A4: which entry an event touched

    @Test("a text delta lands on the open assistant entry, which is the last one")
    func textDeltaFindsTheOpenEntry() {
        var transcript = Transcript()
        transcript.apply(.textDelta("Hello"))
        transcript.apply(.textDelta(", world"))
        let entry = Projection.affectedEntry(in: transcript.entries, for: .textDelta(", world"))
        guard case .assistantText(_, let text) = entry else {
            Issue.record("expected the assistant entry")
            return
        }
        #expect(text == "Hello, world")
        #expect(transcript.entries.count == 1)
    }

    @Test("a tool call is found by the provider's call id, not by position")
    func toolCallFoundByID() {
        var transcript = Transcript()
        transcript.apply(.toolCall(ToolCall(id: "t1", name: "Read", status: .running)))
        transcript.apply(.textDelta("thinking about it"))
        let update = ToolCall(id: "t1", name: "Read", output: "done", status: .succeeded)
        transcript.apply(.toolCall(update))

        let entry = Projection.affectedEntry(in: transcript.entries, for: .toolCall(update))
        guard case .tool(_, let call) = entry else {
            Issue.record("expected the tool entry")
            return
        }
        // `Transcript.upsert` replaced it in place, so it is not the last entry — matching by id is
        // the only rule that finds it.
        #expect(call.status == .succeeded)
        #expect(transcript.entries.first?.id == entry?.id)
    }

    @Test("an event that touches no entry names none")
    func eventsWithoutEntries() {
        var transcript = Transcript()
        transcript.apply(.textDelta("x"))
        let noEntry: [AgentEvent] = [
            .sessionReady(providerSessionID: "s", model: nil),
            .turnStarted(id: "1"),
            .turnEnded(.endTurn),
            .failed(reason: "boom"),
            .usage(Usage()),
            .permissionRequested(PermissionRequest(id: "p", toolName: "Bash", detail: "d", options: [])),
            .thinkingProgress(estimatedTokens: 10),
            .rateLimit(status: "allowed", resetsAt: nil),
            .unrecognized(raw: Data()),
        ]
        for event in noEntry {
            #expect(Projection.affectedEntry(in: transcript.entries, for: event) == nil)
        }
    }

    @Test("a mismatched last entry names nothing rather than the wrong entry")
    func mismatchNamesNothing() {
        // No force-unwrap and no "it must be last": an empty transcript, or one whose last entry is
        // a different kind, produces nil instead of a frame about someone else's entry.
        #expect(Projection.affectedEntry(in: [], for: .textDelta("x")) == nil)
        let notice: [Transcript.Entry] = [.notice(id: UUID(), text: "n")]
        #expect(Projection.affectedEntry(in: notice, for: .textDelta("x")) == nil)
    }

    // MARK: - A5 / FR-23: agent.output

    @Test("agent.output carries the entry's full current text with mode replace")
    func agentOutputIsAReplace() throws {
        let event = frame(after: [.textDelta("Looking at "), .textDelta("AuthGuard.ts…")])
        guard case .agentOutput(let id, let entryId, let kind, let content, let mode) = event else {
            Issue.record("expected agent.output, got \(String(describing: event))")
            return
        }
        #expect(id == sessionId)
        #expect(kind == .assistant)
        #expect(content == "Looking at AuthGuard.ts…")
        // v0 always replaces: the entry's full text, so a client-side delta bug cannot produce a
        // transcript that is wrong but looks right.
        #expect(mode == .replace)
        #expect(UUID(uuidString: entryId) != nil)
    }

    @Test("thinking is its own kind on the same event")
    func thinkingIsAKind() {
        guard case .agentOutput(_, _, let kind, let content, let mode)
            = frame(after: [.thinkingDelta("The JWT check runs before…")]) else {
            Issue.record("expected agent.output")
            return
        }
        #expect(kind == .thinking)
        #expect(content == "The JWT check runs before…")
        #expect(mode == .replace)
    }

    @Test("agent.output is exactly the contract's shape")
    func agentOutputJSON() throws {
        guard case .agentOutput(_, let entryId, _, _, _)
            = frame(after: [.textDelta("hi")]) else {
            Issue.record("expected agent.output")
            return
        }
        let event = BridgeEvent.agentOutput(
            sessionId: sessionId, entryId: entryId, kind: .assistant, content: "hi", mode: .replace
        )
        #expect(try json(event) == #"""
            {"content":"hi","entryId":"\#(entryId)","kind":"assistant","mode":"replace","sessionId":"\#(sessionId)","type":"agent.output"}
            """#)
    }

    // MARK: - The other frames

    @Test("a tool call becomes tool.call with the entry id and the whole call")
    func toolCallFrame() {
        let call = ToolCall(id: "t1", name: "Read", input: "f.swift", status: .running)
        guard case .toolCall(_, let entryId, let dto) = frame(after: [.toolCall(call)]) else {
            Issue.record("expected tool.call")
            return
        }
        #expect(UUID(uuidString: entryId) != nil)
        #expect(dto.id == "t1")
        #expect(dto.status == .running)
    }

    @Test("a plan becomes plan with its items")
    func planFrame() {
        let items = [PlanItem(id: "1", title: "Read", status: .inProgress)]
        guard case .plan(_, _, let dtos) = frame(after: [.plan(items)]) else {
            Issue.record("expected plan")
            return
        }
        #expect(dtos == [PlanItemDTO(id: "1", title: "Read", status: .inProgress)])
    }

    @Test("a rate limit that is not 'allowed' becomes a notice")
    func rateLimitNotice() {
        guard case .notice(_, _, let text)
            = frame(after: [.rateLimit(status: "throttled", resetsAt: nil)]) else {
            Issue.record("expected notice")
            return
        }
        // The same words the window shows — the text comes out of `Transcript`, not out of here.
        #expect(text == "Rate limited: throttled")
    }

    @Test("a permission request becomes permission.requested with the provider's options")
    func permissionFrame() {
        let request = PermissionRequest(
            id: "req_7f2", toolName: "Bash", detail: "curl …",
            options: [PermissionOption(id: "allow", kind: .allowOnce, label: "Allow once")]
        )
        guard case .permissionRequested(_, let dto)
            = frame(after: [.permissionRequested(request)]) else {
            Issue.record("expected permission.requested")
            return
        }
        #expect(dto.id == "req_7f2")
        #expect(dto.options.map(\.id) == ["allow"])
    }

    @Test("usage carries the transcript's merged figure, not the partial report that arrived")
    func usageIsMerged() {
        // Usage arrives more than once per turn and merges field by field. Forwarding the raw event
        // would hand the client a partial that erases fields it already had.
        guard case .usage(_, let dto) = frame(after: [
            .usage(Usage(model: "claude-opus-5", inputTokens: 10)),
            .usage(Usage(outputTokens: 20, costUSD: 0.5)),
        ]) else {
            Issue.record("expected usage")
            return
        }
        #expect(dto.model == "claude-opus-5")
        #expect(dto.inputTokens == 10)
        #expect(dto.outputTokens == 20)
        #expect(dto.costUSD == 0.5)
    }

    // MARK: - The events that produce nothing

    @Test("the events that map to nothing, and why")
    func eventsThatMapToNothing() {
        let silent: [AgentEvent] = [
            // A live estimate is not settled accounting; the transcript drops it too.
            .thinkingProgress(estimatedTokens: 42),
            // The absence of a problem.
            .rateLimit(status: "allowed", resetsAt: nil),
            // Kept in the domain as a visible gap; there is no contract frame to render it as.
            .unrecognized(raw: Data(#"{"type":"whatever"}"#.utf8)),
            // State transitions. They travel through `stateEvents`, on change only — emitting
            // `session.state` from here as well would double every transition.
            .sessionReady(providerSessionID: "s", model: "m"),
            .turnStarted(id: "1"),
            .turnEnded(.endTurn),
            .failed(reason: "boom"),
        ]
        for event in silent {
            #expect(frame(after: [event]) == nil, "\(event) should produce no frame")
        }
    }

    // MARK: - E3: state transitions

    private func state(
        _ status: SessionStatus,
        awaiting: Bool = false,
        error: String? = nil,
        summary: String = ""
    ) -> PublishedState {
        PublishedState(status: status, awaitingUser: awaiting, error: error, summary: summary)
    }

    @Test("nothing changed, nothing published")
    func noChangeNoFrames() {
        let current = state(.running, summary: "same")
        #expect(Projection.stateEvents(sessionId: sessionId, from: current, to: current).isEmpty)
    }

    @Test("a status change publishes session.state")
    func statusChangePublishes() {
        let events = Projection.stateEvents(
            sessionId: sessionId, from: state(.running), to: state(.waiting)
        )
        #expect(events == [.sessionState(
            sessionId: sessionId, status: .waiting, awaitingUser: false, error: nil
        )])
    }

    @Test("a pending permission changes awaitingUser without changing the status")
    func awaitingUserChangePublishes() {
        let events = Projection.stateEvents(
            sessionId: sessionId, from: state(.waiting), to: state(.waiting, awaiting: true)
        )
        #expect(events == [.sessionState(
            sessionId: sessionId, status: .waiting, awaitingUser: true, error: nil
        )])
    }

    @Test("finishing publishes both session.state and session.completed")
    func completionPublishesBoth() {
        let events = Projection.stateEvents(
            sessionId: sessionId, from: state(.running), to: state(.completed)
        )
        #expect(events == [
            .sessionState(sessionId: sessionId, status: .completed, awaitingUser: false, error: nil),
            .sessionCompleted(sessionId: sessionId),
        ])
    }

    @Test("failing publishes session.failed with the error")
    func failurePublishesTheError() {
        let events = Projection.stateEvents(
            sessionId: sessionId,
            from: state(.running),
            to: state(.failed, error: "provider exited with status 1")
        )
        #expect(events == [
            .sessionState(
                sessionId: sessionId, status: .failed, awaitingUser: false,
                error: "provider exited with status 1"
            ),
            .sessionFailed(sessionId: sessionId, error: "provider exited with status 1"),
        ])
    }

    @Test("a cancel reports waiting, never cancelled")
    func cancelReportsWaiting() {
        // FR-11: cancelling a turn leaves the session alive, so the transition that follows is the
        // ordinary `.idle` → `waiting`. Nothing in this file can produce `cancelled`.
        let events = Projection.stateEvents(
            sessionId: sessionId, from: state(.running), to: state(.waiting)
        )
        for event in events {
            if case .sessionState(_, let status, _, _) = event { #expect(status != .cancelled) }
        }
    }

    @Test("a new summary publishes session.summary on its own")
    func summaryChangePublishes() {
        let events = Projection.stateEvents(
            sessionId: sessionId,
            from: state(.running, summary: "old"),
            to: state(.running, summary: "Reading AuthGuard.ts")
        )
        #expect(events == [
            .sessionSummary(sessionId: sessionId, summary: "Reading AuthGuard.ts"),
        ])
    }

    // MARK: - FR-22: every frame is on the wire in the contract's shape

    @Test("every event type round-trips and carries a sessionId")
    func everyEventTypeRoundTrips() throws {
        let all: [BridgeEvent] = [
            .sessionSnapshot(sessionId: sessionId, session: SessionDetailDTO(
                session: ProjectionTests.summary, entries: [], usage: UsageDTO()
            )),
            .sessionCreated(sessionId: sessionId, session: ProjectionTests.summary),
            .sessionState(sessionId: sessionId, status: .running, awaitingUser: false, error: nil),
            .sessionSummary(sessionId: sessionId, summary: "Reading AuthGuard.ts"),
            .agentOutput(
                sessionId: sessionId, entryId: "e", kind: .assistant, content: "…", mode: .replace
            ),
            .toolCall(sessionId: sessionId, entryId: "e", call: ToolCallDTO(
                id: "t", name: "Read", status: .running
            )),
            .plan(sessionId: sessionId, entryId: "e", items: []),
            .notice(sessionId: sessionId, entryId: "e", text: "Rate limited: throttled"),
            .entryAppended(sessionId: sessionId, entry: EntryDTO(
                id: "e", kind: .userText, text: "hi"
            )),
            .permissionRequested(sessionId: sessionId, request: PermissionRequestDTO(
                id: "r", toolName: "Bash", detail: "d", options: []
            )),
            .permissionResolved(sessionId: sessionId, requestId: "r"),
            .usage(sessionId: sessionId, usage: UsageDTO()),
            .sessionCompleted(sessionId: sessionId),
            .sessionFailed(sessionId: sessionId, error: "provider exited with status 1"),
        ]
        let expectedTypes = [
            "session.snapshot", "session.created", "session.state", "session.summary",
            "agent.output", "tool.call", "plan", "notice", "entry.appended",
            "permission.requested", "permission.resolved", "usage", "session.completed",
            "session.failed",
        ]
        #expect(all.map(\.type) == expectedTypes)
        for event in all {
            #expect(event.sessionId == sessionId)
            let text = try json(event)
            #expect(text.contains(#""type":"\#(event.type)""#))
            #expect(text.contains(#""sessionId":"\#(sessionId)""#))
            #expect(try BridgeJSON.decode(BridgeEvent.self, from: Data(text.utf8)) == event)
        }
    }

    @Test("session.state writes a null error rather than omitting it")
    func sessionStateJSON() throws {
        let event = BridgeEvent.sessionState(
            sessionId: sessionId, status: .running, awaitingUser: false, error: nil
        )
        #expect(try json(event) == #"""
            {"awaitingUser":false,"error":null,"sessionId":"\#(sessionId)","status":"running","type":"session.state"}
            """#)
    }

    @Test("only what changes a list row is list-level (FR-21)")
    func listLevelFrames() {
        #expect(BridgeEvent.sessionCreated(
            sessionId: sessionId, session: ProjectionTests.summary
        ).isListLevel)
        #expect(BridgeEvent.sessionState(
            sessionId: sessionId, status: .running, awaitingUser: false, error: nil
        ).isListLevel)
        #expect(BridgeEvent.sessionSummary(sessionId: sessionId, summary: "s").isListLevel)
        #expect(!BridgeEvent.agentOutput(
            sessionId: sessionId, entryId: "e", kind: .assistant, content: "…", mode: .replace
        ).isListLevel)
        #expect(!BridgeEvent.usage(sessionId: sessionId, usage: UsageDTO()).isListLevel)
    }
}
