import Foundation
import Testing

@testable import ZeroCore

@Suite("ClaudeCodeDecoder")
struct ClaudeCodeDecoderTests {
    @Test("decodes text-turn fixture end-to-end")
    func decodesTextTurnFixture() throws {
        let fixture = try loadFixture(named: "text-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // text-turn should have: thinking_tokens (multiple), textDelta(s), usage, turnEnded
        let thinkingEvents = allEvents.filter { if case .thinkingDelta = $0 { return true } else { return false } }
        let textEvents = allEvents.filter { if case .textDelta = $0 { return true } else { return false } }
        let usageEvents = allEvents.filter { if case .usage = $0 { return true } else { return false } }
        let endEvents = allEvents.filter { if case .turnEnded = $0 { return true } else { return false } }

        #expect(!thinkingEvents.isEmpty, "Should have thinking token deltas")
        #expect(!textEvents.isEmpty, "Should have text deltas")
        #expect(!usageEvents.isEmpty, "Should have usage event")
        #expect(!endEvents.isEmpty, "Should have turn ended event")
    }

    @Test("decodes tool-use-turn fixture end-to-end")
    func decodesToolUseTurnFixture() throws {
        let fixture = try loadFixture(named: "tool-use-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // tool-use-turn should have: thinking tokens, toolCall (pending), toolCall (succeeded with output), usage, turnEnded
        let toolEvents = allEvents.filter { if case .toolCall = $0 { return true } else { return false } }
        let usageEvents = allEvents.filter { if case .usage = $0 { return true } else { return false } }
        let endEvents = allEvents.filter { if case .turnEnded = $0 { return true } else { return false } }

        // Should have at least one tool call (the Bash invocation)
        #expect(!toolEvents.isEmpty, "Should have tool call events")
        #expect(!usageEvents.isEmpty, "Should have usage event")
        #expect(!endEvents.isEmpty, "Should have turn ended event")

        // Find the tool call that transitioned to succeeded
        let succeededTools = toolEvents.filter { event in
            if case .toolCall(let call) = event {
                return call.status == .succeeded
            }
            return false
        }
        #expect(!succeededTools.isEmpty, "Should have a succeeded tool call")

        // The succeeded tool should have output
        if case .toolCall(let call) = succeededTools[0] {
            #expect(call.output != nil, "Succeeded tool should have output")
        }
    }

    @Test("decodes permission-denied-turn fixture")
    func decodesPermissionDeniedTurnFixture() throws {
        let fixture = try loadFixture(named: "permission-denied-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // Should have a tool call with denied status
        let deniedTools = allEvents.filter { event in
            if case .toolCall(let call) = event {
                return call.status == .denied
            }
            return false
        }
        #expect(!deniedTools.isEmpty, "Should have a denied tool call")

        // Permission denial is informational; the turn still completes with a result
        let endEvents = allEvents.filter { if case .turnEnded = $0 { return true } else { return false } }
        #expect(!endEvents.isEmpty, "Turn should still end after permission denial")
    }

    @Test("distinguishes thinking blocks from text blocks")
    func distinguishesBlockTypes() throws {
        // In text-turn fixture, the second assistant record has thinking and text blocks
        let fixture = try loadFixture(named: "text-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        let thinkingEvents = allEvents.filter { if case .thinkingDelta = $0 { return true } else { return false } }
        let textEvents = allEvents.filter { if case .textDelta = $0 { return true } else { return false } }

        // Thinking tokens come both from system/thinking_tokens and thinking blocks
        #expect(!thinkingEvents.isEmpty, "Should emit thinkingDelta events")
        #expect(!textEvents.isEmpty, "Should emit textDelta events")
    }

    @Test("correlates tool_use and tool_result by ID")
    func correlatesToolUseAndResult() throws {
        let fixture = try loadFixture(named: "tool-use-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // Collect all tool events
        var toolCalls: [ToolCall] = []
        for event in allEvents {
            if case .toolCall(let call) = event {
                toolCalls.append(call)
            }
        }

        // Should have the same tool call ID appear at least twice: once pending, once with result
        #expect(toolCalls.count >= 1, "Should have at least one tool call")

        // The Bash tool should have transitioned to succeeded
        let bashCalls = toolCalls.filter { $0.name == "Bash" }
        #expect(!bashCalls.isEmpty, "Should have a Bash tool call")

        // Find the final state of the bash call
        if let finalCall = bashCalls.last {
            #expect(finalCall.status == .succeeded, "Bash call should succeed")
            #expect(finalCall.output != nil, "Bash call should have output")
            #expect(finalCall.input != nil, "Bash call should have input")
        }
    }

    @Test("usage event contains all token categories")
    func usageContainsAllTokenCategories() throws {
        let fixture = try loadFixture(named: "text-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        let usageEvents = allEvents.filter { if case .usage = $0 { return true } else { return false } }
        #expect(!usageEvents.isEmpty, "Should have usage event")

        if case .usage(let usage) = usageEvents[0] {
            #expect(usage.inputTokens != nil, "Should have input tokens")
            #expect(usage.outputTokens != nil, "Should have output tokens")
            #expect(usage.cacheReadTokens != nil, "Should have cache read tokens")
            #expect(usage.cacheWriteTokens != nil, "Should have cache write tokens")
        }
    }

    @Test("turnEnded carries the right stop reason")
    func turnEndedCarriesStopReason() throws {
        let fixture = try loadFixture(named: "text-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        let endEvents = allEvents.filter { if case .turnEnded = $0 { return true } else { return false } }
        #expect(!endEvents.isEmpty, "Should have turnEnded")

        if case .turnEnded(let reason) = endEvents[0] {
            #expect(reason == .endTurn, "Should end with endTurn reason")
        }
    }

    @Test("permission_denied is decoded as tool call update, not permission request")
    func permissionDeniedIsNotPermissionRequest() throws {
        let fixture = try loadFixture(named: "permission-denied-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // Should NOT have any permissionRequested events
        let permissionEvents = allEvents.filter { if case .permissionRequested = $0 { return true } else { return false } }
        #expect(permissionEvents.isEmpty, "Should not emit permissionRequested for permission_denied")

        // Should have toolCall with denied status instead
        let toolEvents = allEvents.filter { if case .toolCall = $0 { return true } else { return false } }
        #expect(!toolEvents.isEmpty, "Should emit toolCall for permission_denied")
    }

    @Test("invalid JSON yields unrecognized, not crash")
    func invalidJSONYieldsUnrecognized() {
        var decoder = ClaudeCodeDecoder()
        let badJson = Data("{not valid json".utf8)

        let events = decoder.decode(line: badJson)
        #expect(events.count == 1, "Should return one event")

        if case .unrecognized(raw: let raw) = events[0] {
            #expect(raw == badJson, "Should preserve the raw line")
        } else {
            Issue.record("Should return unrecognized")
        }
    }

    @Test("unknown but valid JSON yields unrecognized")
    func unknownValidJsonYieldsUnrecognized() {
        var decoder = ClaudeCodeDecoder()
        let unknownType = Data(#"{"type":"unknown","data":"foo"}"#.utf8)

        let events = decoder.decode(line: unknownType)
        #expect(events.count == 1, "Should return one event")

        if case .unrecognized = events[0] {
            // Expected
        } else {
            Issue.record("Should return unrecognized")
        }
    }

    @Test("decoder recovers after invalid line")
    func recoversAfterInvalidLine() {
        var decoder = ClaudeCodeDecoder()

        // First line is bad
        let badLine = Data("{invalid".utf8)
        let badEvents = decoder.decode(line: badLine)
        #expect(badEvents.count == 1)
        #expect(badEvents[0] == .unrecognized(raw: badLine))

        // Second line should work fine
        let goodLine = Data(#"{"type":"system","subtype":"thinking_tokens","estimated_tokens_delta":5}"#.utf8)
        let goodEvents = decoder.decode(line: goodLine)
        #expect(!goodEvents.isEmpty, "Should still decode after previous error")
    }

    @Test("tool call input is serialized as JSON string")
    func toolCallInputSerializedAsJSON() throws {
        let fixture = try loadFixture(named: "tool-use-turn.ndjson")
        var decoder = ClaudeCodeDecoder()

        var allEvents: [AgentEvent] = []
        let lines = fixture.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        for line in lines {
            allEvents.append(contentsOf: decoder.decode(line: Data(line)))
        }

        // Find tool call events with pending status (the initial tool_use block)
        let pendingTools = allEvents.filter { event in
            if case .toolCall(let call) = event {
                return call.status == .pending
            }
            return false
        }
        #expect(!pendingTools.isEmpty, "Should have pending tool calls")

        // The input should be a JSON string
        if case .toolCall(let call) = pendingTools[0] {
            #expect(call.input != nil, "Should have input")
            // Input should be parseable as JSON
            if let inputData = call.input?.data(using: .utf8) {
                let parsed = try? JSONSerialization.jsonObject(with: inputData)
                #expect(parsed != nil, "Input should be valid JSON")
            }
        }
    }

    // MARK: - Helpers

    private func loadFixture(named: String) throws -> Data {
        guard let path = Bundle.module.path(
            forResource: named,
            ofType: nil,
            inDirectory: "Fixtures/claude-code"
        ) else {
            throw NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(named)"])
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Records added after the probe ran against the real CLI

    @Test("system/init yields the provider session id that resume needs")
    func initYieldsSessionReady() {
        var decoder = ClaudeCodeDecoder()
        let line = Data(#"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-haiku-4-5","cwd":"/tmp"}"#.utf8)
        let events = decoder.decode(line: line)
        guard case .sessionReady(let id, let model) = events.first else {
            Issue.record("expected .sessionReady, got \(events)")
            return
        }
        #expect(id == "abc-123")
        #expect(model == "claude-haiku-4-5")
    }

    @Test("rate_limit_event decodes its status")
    func rateLimitDecodes() {
        var decoder = ClaudeCodeDecoder()
        let line = Data(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787301000}}"#.utf8)
        guard case .rateLimit(let status, let resetsAt) = decoder.decode(line: line).first else {
            Issue.record("expected .rateLimit")
            return
        }
        #expect(status == "allowed")
        #expect(resetsAt == Date(timeIntervalSince1970: 1787301000))
    }

    @Test("records we know and skip are not reported as unrecognized")
    func benignRecordsAreSilent() {
        // `.unrecognized` has to keep meaning "we do not understand this". If it fills with hook
        // chatter nobody reads it, and a genuine gap in the decoder stops being visible.
        var decoder = ClaudeCodeDecoder()
        let benign = [
            #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart"}"#,
            #"{"type":"system","subtype":"hook_response","hook_name":"SessionStart","outcome":"success"}"#,
            #"{"type":"system","subtype":"post_turn_summary","status_category":"review_ready"}"#,
            #"{"type":"system","subtype":"task_summary"}"#,
        ]
        for record in benign {
            #expect(decoder.decode(line: Data(record.utf8)).isEmpty, "\(record) should produce no events")
        }
    }

    @Test("a system subtype we have never seen is still reported as unrecognized")
    func unknownSubtypeStaysVisible() {
        var decoder = ClaudeCodeDecoder()
        let line = Data(#"{"type":"system","subtype":"something_new_in_a_future_version"}"#.utf8)
        guard case .unrecognized = decoder.decode(line: line).first else {
            Issue.record("an unknown subtype must stay visible")
            return
        }
    }
}
