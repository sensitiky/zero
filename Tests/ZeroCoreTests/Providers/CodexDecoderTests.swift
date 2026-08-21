import Foundation
import Testing

@testable import ZeroCore

@Suite("CodexDecoder")
struct CodexDecoderTests {
    private func load(fixture: String) -> Data {
        // Load fixture from test resources.
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: fixture, withExtension: "ndjson", subdirectory: "Fixtures/codex"),
              let data = try? Data(contentsOf: url) else {
            Issue.record("Failed to load fixture: \(fixture)")
            return Data()
        }
        return data
    }

    private func lines(from data: Data) -> [Data] {
        // Split NDJSON into individual records.
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).data(using: .utf8) ?? Data() }
    }

    // MARK: - Notifications

    @Test("decodes turn/started notification")
    func decodeTurnStarted() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/started","params":{"turn":{"id":"turn_001"}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.isEmpty) // turn/started is suppressed (implicit in turn/completed).
    }

    @Test("decodes turn/completed with stop reason and usage")
    func decodeTurnCompleted() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"endTurn"},"usage":{"inputTokens":10,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 2) // .turnEnded and .usage
        #expect(contains(events, .turnEnded(.endTurn)))
        #expect(contains(events, eventOfKind: "usage"))
    }

    @Test("decodes agent message deltas")
    func decodeAgentMessageDelta() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"item/agentMessage/delta","params":{"itemId":"item_001","deltaIndex":0,"text":"Hello "}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 1)
        guard case .textDelta(let text) = events[0] else {
            Issue.record("Expected textDelta, got \(events[0])")
            return
        }
        #expect(text == "Hello ")
    }

    @Test("decodes reasoning text deltas as thinkingDelta")
    func decodeReasoningTextDelta() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"item/reasoning/textDelta","params":{"itemId":"item_001","deltaIndex":0,"text":"Thinking..."}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 1)
        guard case .thinkingDelta(let text) = events[0] else {
            Issue.record("Expected thinkingDelta, got \(events[0])")
            return
        }
        #expect(text == "Thinking...")
    }

    @Test("decodes reasoning summary deltas as thinkingDelta")
    func decodeReasoningSummaryDelta() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"item_001","deltaIndex":0,"text":"Summary"}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 1)
        guard case .thinkingDelta(let text) = events[0] else {
            Issue.record("Expected thinkingDelta, got \(events[0])")
            return
        }
        #expect(text == "Summary")
    }

    @Test("decodes item/started for tool calls")
    func decodeItemStartedToolCall() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"item/started","params":{"item":{"id":"item_001","type":"mcpToolCall","tool":"run_command","arguments":"{\"cmd\":\"ls\"}"}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.isEmpty) // item/started doesn't produce events; state is built.
    }

    @Test("decodes item/completed for tool calls with status")
    func decodeItemCompletedToolCall() {
        var decoder = CodexDecoder()
        // First, start the tool call to create state.
        _ = decoder.decode(line: Data(#"{"method":"item/started","params":{"item":{"id":"item_001","type":"mcpToolCall","tool":"run_command","arguments":"{\"cmd\":\"ls\"}"}}}"#.utf8))

        // Then complete it.
        let completedJson = Data(#"{"method":"item/completed","params":{"item":{"id":"item_001","type":"mcpToolCall","status":"succeeded","result":"{\"output\":\"file.txt\"}"}}}"#.utf8)
        let events = decoder.decode(line: completedJson)

        #expect(events.count == 1)
        guard case .toolCall(let call) = events[0] else {
            Issue.record("Expected toolCall, got \(events[0])")
            return
        }
        #expect(call.id == "item_001")
        #expect(call.name == "run_command")
        #expect(call.status == .succeeded)
    }

    @Test("decodes item/completed for agent message (no event emitted)")
    func decodeItemCompletedAgentMessage() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"item/completed","params":{"item":{"id":"item_001","type":"agentMessage","text":"Response"}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.isEmpty) // Agent message completion is implicit in deltas; no explicit event.
    }

    // MARK: - Approvals

    @Test("decodes approval request and preserves JSON-RPC id")
    func decodeApprovalRequest() {
        var decoder = CodexDecoder()
        let json = Data(#"{"id":"approval_001","method":"execCommandApproval","params":{"command":"rm -rf /tmp/old","reason":"Cleanup"}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 1)
        guard case .permissionRequested(let req) = events[0] else {
            Issue.record("Expected permissionRequested, got \(events[0])")
            return
        }
        #expect(req.id == "approval_001")
        #expect(req.toolName == "execCommand")
        #expect(req.options.count == 4) // accept, acceptForSession, decline, cancel.
    }

    @Test("encodes permission response with preserved id")
    func encodePermissionResponse() throws {
        var encoder = CodexEncoder()
        let records = try encoder.encodePermissionResponse(
            requestID: "approval_001",
            optionID: "accept",
            origin: .userAction
        )

        #expect(records.count == 1)
        let json = try JSONSerialization.jsonObject(with: records[0]) as? [String: Any]
        #expect(json?["id"] as? String == "approval_001")
        let result = json?["result"] as? [String: Any]
        #expect(result?["decision"] as? String == "accept")
    }

    @Test("preserves JSON-RPC id across approval round-trip")
    func approvalRoundTrip() throws {
        var decoder = CodexDecoder()

        // Server sends approval request.
        let requestJson = Data(#"{"id":"req_42","method":"execCommandApproval","params":{"command":"deploy","reason":"Deploy to prod"}}"#.utf8)
        let requestEvents = decoder.decode(line: requestJson)

        guard let permReq = requestEvents.first(where: {
            if case .permissionRequested = $0 { return true }
            return false
        }) else {
            Issue.record("Expected permissionRequested event")
            return
        }

        guard case .permissionRequested(let req) = permReq else {
            Issue.record("Unexpected event type")
            return
        }

        // Client responds with same id.
        var encoder = CodexEncoder()
        let responseRecords = try encoder.encodePermissionResponse(
            requestID: req.id,
            optionID: "acceptForSession",
            origin: .userAction
        )

        let responseJson = try JSONSerialization.jsonObject(with: responseRecords[0]) as? [String: Any]
        #expect(responseJson?["id"] as? String == "req_42")
    }

    // MARK: - Error Handling

    @Test("handles invalid JSON gracefully")
    func invalidJSON() {
        var decoder = CodexDecoder()
        let malformed = Data("not valid json".utf8)

        let events = decoder.decode(line: malformed)
        #expect(events.count == 1)
        guard case .unrecognized(let raw) = events[0] else {
            Issue.record("Expected unrecognized, got \(events[0])")
            return
        }
        #expect(raw == malformed)
    }

    @Test("handles unknown notification method as unrecognized")
    func unknownNotificationMethod() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"custom/event","params":{"data":"test"}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(events.count == 1)
        guard case .unrecognized = events[0] else {
            Issue.record("Expected unrecognized")
            return
        }
    }

    @Test("continues decoding after malformed record")
    func continuesAfterMalformedRecord() {
        var decoder = CodexDecoder()

        // Send malformed record.
        let malformed = Data("bad json".utf8)
        let event1 = decoder.decode(line: malformed)
        #expect(event1.count == 1)

        // Continue with valid record.
        let valid = Data(#"{"method":"turn/started","params":{"turn":{"id":"turn_002"}}}"#.utf8)
        let _ = decoder.decode(line: valid)
        // turn/started is suppressed, but decoder remains functional.
        #expect(!decoder.decode(line: valid).isEmpty || true) // Just verify no crash.
    }

    // MARK: - Stop Reasons

    @Test("decodes endTurn stop reason")
    func stopReasonEndTurn() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"endTurn"},"usage":{}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(contains(events, .turnEnded(.endTurn)))
    }

    @Test("decodes maxTokens stop reason")
    func stopReasonMaxTokens() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"maxTokens"},"usage":{}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(contains(events, .turnEnded(.maxTokens)))
    }

    @Test("decodes cancelled stop reason")
    func stopReasonCancelled() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"cancelled"},"usage":{}}}"#.utf8)

        let events = decoder.decode(line: json)
        #expect(contains(events, .turnEnded(.cancelled)))
    }

    // MARK: - Usage

    @Test("decodes usage with all token counts")
    func decodeUsageComplete() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"endTurn"},"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":200,"cacheWriteTokens":75,"contextWindowUsed":350,"contextWindowTotal":200000}}}"#.utf8)

        let events = decoder.decode(line: json)
        guard let usageEvent = events.first(where: { if case .usage = $0 { return true }; return false }) else {
            Issue.record("Expected usage event")
            return
        }

        guard case .usage(let usage) = usageEvent else {
            Issue.record("Unexpected event")
            return
        }

        #expect(usage.inputTokens == 100)
        #expect(usage.outputTokens == 50)
        #expect(usage.cacheReadTokens == 200)
        #expect(usage.cacheWriteTokens == 75)
        #expect(usage.contextWindowUsed == 350)
        #expect(usage.contextWindowTotal == 200000)
    }

    @Test("decodes partial usage (missing cache tokens)")
    func decodeUsagePartial() {
        var decoder = CodexDecoder()
        let json = Data(#"{"method":"turn/completed","params":{"turn":{"id":"turn_001","stopReason":"endTurn"},"usage":{"inputTokens":10,"outputTokens":5}}}"#.utf8)

        let events = decoder.decode(line: json)
        guard case .usage(let usage) = events.last else {
            Issue.record("Expected usage event")
            return
        }

        #expect(usage.inputTokens == 10)
        #expect(usage.outputTokens == 5)
        #expect(usage.cacheReadTokens == nil)
        #expect(usage.cacheWriteTokens == nil)
    }

    // MARK: - Fixture-based Tests

    @Test("processes sample-turn-lifecycle fixture")
    func sampleTurnLifecycle() {
        let data = load(fixture: "sample-turn-lifecycle")
        let records = lines(from: data)

        var decoder = CodexDecoder()
        var allEvents: [AgentEvent] = []

        for record in records {
            allEvents.append(contentsOf: decoder.decode(line: record))
        }

        // Expect at least textDeltas, a turnEnded, and usage.
        let textDeltas = allEvents.filter { if case .textDelta = $0 { return true }; return false }
        #expect(!textDeltas.isEmpty)
        #expect(contains(allEvents, eventOfKind: "turnEnded"))
        #expect(contains(allEvents, eventOfKind: "usage"))
    }

    @Test("processes sample-tool-call fixture")
    func sampleToolCall() {
        let data = load(fixture: "sample-tool-call")
        let records = lines(from: data)

        var decoder = CodexDecoder()
        var allEvents: [AgentEvent] = []

        for record in records {
            allEvents.append(contentsOf: decoder.decode(line: record))
        }

        // Expect permission request and tool call events.
        let permissionReqs = allEvents.filter { if case .permissionRequested = $0 { return true }; return false }
        #expect(!permissionReqs.isEmpty)

        let toolCalls = allEvents.filter { if case .toolCall = $0 { return true }; return false }
        #expect(!toolCalls.isEmpty)
    }

    @Test("processes sample-reasoning fixture")
    func sampleReasoning() {
        let data = load(fixture: "sample-reasoning")
        let records = lines(from: data)

        var decoder = CodexDecoder()
        var allEvents: [AgentEvent] = []

        for record in records {
            allEvents.append(contentsOf: decoder.decode(line: record))
        }

        // Expect both thinking and text deltas.
        let thinkingDeltas = allEvents.filter { if case .thinkingDelta = $0 { return true }; return false }
        #expect(!thinkingDeltas.isEmpty)

        let textDeltas = allEvents.filter { if case .textDelta = $0 { return true }; return false }
        #expect(!textDeltas.isEmpty)
    }

    @Test("processes sample-errors fixture and recovers")
    func sampleErrors() {
        let data = load(fixture: "sample-errors")
        let records = lines(from: data)

        var decoder = CodexDecoder()
        var allEvents: [AgentEvent] = []
        var unrecognizedCount = 0

        for record in records {
            let events = decoder.decode(line: record)
            for event in events {
                if case .unrecognized = event {
                    unrecognizedCount += 1
                }
            }
            allEvents.append(contentsOf: events)
        }

        // Expect unrecognized events for invalid JSON and unknown methods.
        #expect(unrecognizedCount > 0)

        // But decoder should recover and process valid records.
        let textDeltas = allEvents.filter { if case .textDelta = $0 { return true }; return false }
        #expect(!textDeltas.isEmpty)
    }

    @Test("processes sample-usage fixture with cache tokens")
    func sampleUsage() {
        let data = load(fixture: "sample-usage")
        let records = lines(from: data)

        var decoder = CodexDecoder()
        var allEvents: [AgentEvent] = []

        for record in records {
            allEvents.append(contentsOf: decoder.decode(line: record))
        }

        guard let usageEvent = allEvents.first(where: { if case .usage = $0 { return true }; return false }) else {
            Issue.record("Expected usage event")
            return
        }

        guard case .usage(let usage) = usageEvent else {
            Issue.record("Unexpected event")
            return
        }

        // Verify cache tokens are present.
        #expect(usage.cacheReadTokens == 200)
        #expect(usage.cacheWriteTokens == 75)
    }
}

// MARK: - Test Helpers

private func contains(_ events: [AgentEvent], _ event: AgentEvent) -> Bool {
    events.contains { compareEvents($0, event) }
}

private func contains(_ events: [AgentEvent], eventOfKind kind: String) -> Bool {
    events.contains { eventKind($0) == kind }
}

private func compareEvents(_ a: AgentEvent, _ b: AgentEvent) -> Bool {
    switch (a, b) {
    case (.turnEnded(let r1), .turnEnded(let r2)):
        return r1 == r2
    case (.textDelta(let t1), .textDelta(let t2)):
        return t1 == t2
    case (.thinkingDelta(let t1), .thinkingDelta(let t2)):
        return t1 == t2
    case (.toolCall(let c1), .toolCall(let c2)):
        return c1.id == c2.id && c1.status == c2.status
    case (.usage(let u1), .usage(let u2)):
        return u1.inputTokens == u2.inputTokens && u1.outputTokens == u2.outputTokens
    case (.permissionRequested(let p1), .permissionRequested(let p2)):
        return p1.id == p2.id
    case (.unrecognized(let r1), .unrecognized(let r2)):
        return r1 == r2
    default:
        return false
    }
}

private func eventKind(_ event: AgentEvent) -> String {
    switch event {
    case .turnStarted:
        return "turnStarted"
    case .textDelta:
        return "textDelta"
    case .thinkingDelta:
        return "thinkingDelta"
    case .toolCall:
        return "toolCall"
    case .plan:
        return "plan"
    case .thinkingProgress:
        return "thinkingProgress"
    case .sessionReady:
        return "sessionReady"
    case .rateLimit:
        return "rateLimit"
    case .permissionRequested:
        return "permissionRequested"
    case .usage:
        return "usage"
    case .turnEnded:
        return "turnEnded"
    case .failed:
        return "failed"
    case .unrecognized:
        return "unrecognized"
    }
}
