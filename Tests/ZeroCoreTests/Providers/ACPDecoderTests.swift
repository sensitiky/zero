import Foundation
import Testing

@testable import ZeroCore

@Suite("ACPDecoder")
struct ACPDecoderTests {
    // MARK: - Helper Methods

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func decode(_ json: String) -> [AgentEvent] {
        var decoder = ACPDecoder()
        return decoder.decode(line: self.json(json))
    }

    // MARK: - Agent Message Chunks

    @Test("decodes agent text message chunk")
    func decodesAgentMessageChunk() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg_001","content":{"type":"text","text":"Hello, world!"}}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        #expect(events[0] == .textDelta("Hello, world!"))
    }

    @Test("ignores non-text content in message chunks")
    func ignoresNonTextContent() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","mimeType":"image/png","data":"abc123"}}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .unrecognized = events[0] {
            // Expected
        } else {
            #expect(Bool(false), "Should be unrecognized for non-text content")
        }
    }

    // MARK: - Tool Calls

    @Test("decodes tool call creation")
    func decodesToolCall() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"tool_call","toolCallId":"call_001","title":"Read file","kind":"read","status":"pending"}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .toolCall(let tc) = events[0] {
            #expect(tc.id == "call_001")
            #expect(tc.name == "Read file")
            #expect(tc.status == .pending)
        } else {
            #expect(Bool(false), "Should be toolCall event")
        }
    }

    @Test("decodes tool call update with in_progress status")
    func decodesToolCallUpdate() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_001","status":"in_progress"}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .toolCall(let tc) = events[0] {
            #expect(tc.id == "call_001")
            #expect(tc.status == .running)
        } else {
            #expect(Bool(false), "Should be toolCall event")
        }
    }

    @Test("decodes tool call with file edit")
    func decodesToolCallWithFileEdit() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_001","status":"completed","content":[{"type":"diff","path":"/home/user/file.txt","oldText":"old","newText":"new"}]}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .toolCall(let tc) = events[0] {
            #expect(tc.status == .succeeded)
            #expect(tc.edit?.path == "/home/user/file.txt")
            #expect(tc.edit?.oldText == "old")
            #expect(tc.edit?.newText == "new")
        } else {
            #expect(Bool(false), "Should be toolCall event with edit")
        }
    }

    @Test("maps tool call statuses correctly")
    func mapsToolCallStatuses() {
        let testCases: [(String, ToolCall.Status)] = [
            ("pending", .pending),
            ("in_progress", .running),
            ("completed", .succeeded),
            ("failed", .failed("")),
            ("cancelled", .denied),
        ]

        for (statusStr, expectedStatus) in testCases {
            let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_001","status":"\#(statusStr)"}}}"#
            let events = decode(json)

            #expect(events.count == 1)
            if case .toolCall(let tc) = events[0] {
                #expect(tc.status == expectedStatus, "Status \(statusStr) should map to \(expectedStatus)")
            }
        }
    }

    // MARK: - Plans

    @Test("decodes plan with multiple entries")
    func decodesPlan() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"plan","entries":[{"content":"Task 1","priority":"high","status":"pending"},{"content":"Task 2","priority":"medium","status":"in_progress"},{"content":"Task 3","priority":"low","status":"completed"}]}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .plan(let items) = events[0] {
            #expect(items.count == 3)
            #expect(items[0].title == "Task 1")
            #expect(items[0].status == .pending)
            #expect(items[1].title == "Task 2")
            #expect(items[1].status == .inProgress)
            #expect(items[2].title == "Task 3")
            #expect(items[2].status == .completed)
        } else {
            #expect(Bool(false), "Should be plan event")
        }
    }

    // MARK: - Usage Updates

    @Test("decodes usage update")
    func decodesUsageUpdate() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"usage_update","used":53000,"size":200000}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .usage(let usage) = events[0] {
            #expect(usage.contextWindowUsed == 53000)
            #expect(usage.contextWindowTotal == 200000)
        } else {
            #expect(Bool(false), "Should be usage event")
        }
    }

    // MARK: - Permission Requests

    @Test("decodes permission request with id preserved")
    func decodesPermissionRequest() {
        let json = #"{"jsonrpc":"2.0","id":5,"method":"session/request_permission","params":{"sessionId":"sess_abc","toolCall":{"toolCallId":"call_001"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .permissionRequested(let req) = events[0] {
            #expect(req.id == "5", "Request ID should be preserved as string")
            #expect(req.toolName == "call_001")
            #expect(req.options.count == 2)
            #expect(req.options[0].id == "allow")
            #expect(req.options[0].kind == .allowOnce)
            #expect(req.options[1].id == "deny")
            #expect(req.options[1].kind == .denyOnce)
        } else {
            #expect(Bool(false), "Should be permissionRequested event")
        }
    }

    @Test("maps permission option kinds")
    func mapsPermissionOptionKinds() {
        let testCases: [(String, PermissionOption.Kind)] = [
            ("allow_once", .allowOnce),
            ("allow_always", .allowAlways),
            ("reject_once", .denyOnce),
            ("reject_always", .denyAlways),
        ]

        for (kindStr, expectedKind) in testCases {
            let json = #"{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"sess_test","toolCall":{"toolCallId":"call_001"},"options":[{"optionId":"opt","name":"Option","kind":"\#(kindStr)"}]}}"#
            let events = decode(json)

            if case .permissionRequested(let req) = events[0] {
                #expect(req.options[0].kind == expectedKind, "Kind \(kindStr) should map correctly")
            }
        }
    }

    // MARK: - Turn Completion

    @Test("decodes all stop reasons")
    func decodesStopReasons() {
        let testCases: [(String, StopReason)] = [
            ("end_turn", .endTurn),
            ("max_tokens", .maxTokens),
            ("cancelled", .cancelled),
            ("refusal", .refusal),
        ]

        for (reasonStr, expectedReason) in testCases {
            let json = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"\#(reasonStr)"}}"#
            let events = decode(json)

            #expect(events.count == 1)
            if case .turnEnded(let reason) = events[0] {
                #expect(reason == expectedReason, "Stop reason \(reasonStr) should map correctly")
            } else {
                #expect(Bool(false), "Should be turnEnded event")
            }
        }
    }

    // MARK: - Error Handling

    @Test("handles invalid JSON without crashing")
    func handlesInvalidJson() {
        let invalidJson = "not valid json at all"
        let events = decode(invalidJson)

        #expect(events.count == 1)
        if case .unrecognized = events[0] {
            // Expected
        } else {
            #expect(Bool(false), "Should return unrecognized for invalid JSON")
        }
    }

    @Test("handles unknown methods as unrecognized")
    func handlesUnknownMethods() {
        let json = #"{"jsonrpc":"2.0","method":"unknown/method","params":{}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .unrecognized = events[0] {
            // Expected
        } else {
            #expect(Bool(false), "Should return unrecognized for unknown method")
        }
    }

    @Test("handles malformed session/update")
    func handlesMalformedSessionUpdate() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test"}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .unrecognized = events[0] {
            // Expected
        } else {
            #expect(Bool(false), "Should return unrecognized for malformed update")
        }
    }

    @Test("ignores mode changes (current_mode_update)")
    func ignoresModeChanges() {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"current_mode_update","modeId":"code"}}}"#
        let events = decode(json)

        #expect(events.count == 1)
        if case .unrecognized = events[0] {
            // Expected - mode changes don't fit AgentEvent model
        } else {
            #expect(Bool(false), "Should return unrecognized for mode changes")
        }
    }

    // MARK: - Stateful Decoding

    @Test("continues after error")
    func continuesAfterError() {
        var decoder = ACPDecoder()

        // First, invalid JSON
        let invalidEvents = decoder.decode(line: json("not json"))
        #expect(invalidEvents.count == 1)
        if case .unrecognized = invalidEvents[0] {
            // Expected
        } else {
            #expect(Bool(false))
        }

        // Then, valid message should still decode
        let validJson = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"recovered"}}}}"#
        let validEvents = decoder.decode(line: json(validJson))
        #expect(validEvents.count == 1)
        if case .textDelta(let text) = validEvents[0] {
            #expect(text == "recovered")
        } else {
            #expect(Bool(false))
        }
    }

    // MARK: - Loading Fixtures

    @Test("loads initialize fixture")
    func loadsFixture() throws {
        let data = try loadFixture("initialize")
        #expect(!data.isEmpty)

        var decoder = ACPDecoder()
        let events = decoder.decode(line: data)
        // The initialize request comes FROM the client, so the decoder sees it as a notification
        // which doesn't match any known method, so it becomes unrecognized
        #expect(events.count == 1)
    }

    @Test("loads and parses session-updates fixture")
    func loadsSessionUpdatesFixture() throws {
        let data = try loadFixture("session-updates")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

        var decoder = ACPDecoder()
        var eventCounts: [Int] = []

        for line in lines where !line.isEmpty {
            let events = decoder.decode(line: Data(line.utf8))
            eventCounts.append(events.count)
        }

        // Should have decoded multiple messages
        #expect(eventCounts.count == 7)

        // First should be text delta, second tool call, etc.
        #expect(eventCounts[0] == 1) // agent_message_chunk
        #expect(eventCounts[1] == 1) // tool_call
        #expect(eventCounts[2] == 1) // tool_call_update
        #expect(eventCounts[3] == 1) // tool_call_update with diff
        #expect(eventCounts[4] == 1) // plan
        #expect(eventCounts[5] == 1) // usage_update
        #expect(eventCounts[6] == 1) // current_mode_update (unrecognized)
    }

    // MARK: - Private Helpers

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures/acp") else {
            throw DecoderError("Fixture \(name).ndjson not found")
        }
        return try Data(contentsOf: url)
    }
}
