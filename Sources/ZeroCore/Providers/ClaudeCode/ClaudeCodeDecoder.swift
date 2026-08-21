import Foundation

/// Decodes Claude Code (claude CLI) stream-json output into normalized AgentEvent.
///
/// Stream is NDJSON with record types: system (init, thinking_tokens, task_summary,
/// post_turn_summary, permission_denied), assistant (message with content blocks),
/// user (with tool_result blocks), rate_limit_event, and result (with usage and cost).
public struct ClaudeCodeDecoder: ProtocolDecoder {
    // Correlate tool_use blocks to their later tool_results
    private var pendingToolCalls: [String: ToolCall] = [:]

    public init() {}

    public mutating func decode(line: Data) -> [AgentEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return [.unrecognized(raw: line)]
        }

        guard let type = json["type"] as? String else {
            return [.unrecognized(raw: line)]
        }

        switch type {
        case "system":
            return decodeSystem(json: json, raw: line)
        case "assistant":
            return decodeAssistant(json: json, raw: line)
        case "user":
            return decodeUser(json: json, raw: line)
        case "rate_limit_event":
            // Rate limits don't fit AgentEvent; keep as unrecognized
            return [.unrecognized(raw: line)]
        case "result":
            return decodeResult(json: json, raw: line)
        default:
            return [.unrecognized(raw: line)]
        }
    }

    // MARK: - System Records

    private mutating func decodeSystem(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let subtype = json["subtype"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        switch subtype {
        case "init":
            // Session init doesn't directly map to AgentEvent
            return [.unrecognized(raw: raw)]
        case "thinking_tokens":
            return decodeThinkingTokens(json: json, raw: raw)
        case "post_turn_summary":
            // Summary doesn't fit AgentEvent
            return [.unrecognized(raw: raw)]
        case "task_summary":
            // Task summary doesn't fit AgentEvent
            return [.unrecognized(raw: raw)]
        case "permission_denied":
            return decodePermissionDenied(json: json, raw: raw)
        default:
            return [.unrecognized(raw: raw)]
        }
    }

    private func decodeThinkingTokens(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let delta = json["estimated_tokens_delta"] as? Int else {
            return [.unrecognized(raw: raw)]
        }
        // A running estimate, not thinking prose: emitting it as `.thinkingDelta` would splice
        // digits into the transcript, and as `.usage` it would be mistaken for the turn's total.
        return [.thinkingProgress(estimatedTokens: delta)]
    }

    private mutating func decodePermissionDenied(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let toolUseID = json["tool_use_id"] as? String else {
            return [.unrecognized(raw: raw)]
        }
        // Update the pending tool call with denied status
        if var toolCall = pendingToolCalls.removeValue(forKey: toolUseID) {
            toolCall.status = ToolCall.Status.denied
            return [.toolCall(toolCall)]
        }
        // If no pending call, still emit as informational
        return [.unrecognized(raw: raw)]
    }

    // MARK: - Assistant Records

    private mutating func decodeAssistant(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any] else {
            return [.unrecognized(raw: raw)]
        }

        guard let content = message["content"] as? [[String: Any]] else {
            return [.unrecognized(raw: raw)]
        }

        var events: [AgentEvent] = []

        for block in content {
            guard let blockType = block["type"] as? String else {
                continue
            }

            switch blockType {
            case "thinking":
                if let thinking = block["thinking"] as? String {
                    events.append(.thinkingDelta(thinking))
                }
            case "text":
                if let text = block["text"] as? String {
                    events.append(.textDelta(text))
                }
            case "tool_use":
                if let toolUseEvent = decodeToolUseBlock(block: block) {
                    events.append(toolUseEvent)
                }
            default:
                continue
            }
        }

        return events
    }

    private mutating func decodeToolUseBlock(block: [String: Any]) -> AgentEvent? {
        guard let toolUseID = block["id"] as? String,
              let toolName = block["name"] as? String else {
            return nil
        }

        let inputDict = block["input"] as? [String: Any]

        // Serialize the input object to a JSON string
        let inputStr: String?
        if let inputDict,
           let jsonData = try? JSONSerialization.data(
               withJSONObject: inputDict,
               options: [.sortedKeys]
           ) {
            inputStr = String(decoding: jsonData, as: UTF8.self)
        } else {
            inputStr = nil
        }

        let toolCall = ToolCall(
            id: toolUseID,
            name: toolName,
            input: inputStr,
            output: nil,
            status: .pending,
            edit: inputDict.flatMap { fileEdit(toolName: toolName, input: $0) }
        )
        pendingToolCalls[toolUseID] = toolCall
        return .toolCall(toolCall)
    }

    // MARK: - User Records

    private mutating func decodeUser(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return [.unrecognized(raw: raw)]
        }

        var events: [AgentEvent] = []

        for block in content {
            guard block["type"] as? String == "tool_result",
                  let toolUseID = block["tool_use_id"] as? String else {
                continue
            }

            let isError = block["is_error"] as? Bool ?? false
            let output = block["content"] as? String

            // Update the pending tool call
            if var toolCall = pendingToolCalls.removeValue(forKey: toolUseID) {
                toolCall.output = output
                toolCall.status = isError ? ToolCall.Status.failed(output ?? "Unknown error") : .succeeded
                events.append(.toolCall(toolCall))
            }
        }

        return events
    }

    // MARK: - Result Records

    private func decodeResult(json: [String: Any], raw: Data) -> [AgentEvent] {
        guard let subtype = json["subtype"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        guard subtype == "success" else {
            return [.unrecognized(raw: raw)]
        }

        var events: [AgentEvent] = []

        // Extract usage information
        if let usage = json["usage"] as? [String: Any] {
            let usageEvent = parseUsage(
                usage: usage,
                model: json["model"] as? String,
                costUSD: json["total_cost_usd"] as? Double
            )
            events.append(.usage(usageEvent))
        }

        // Determine stop reason
        let stopReasonStr = json["stop_reason"] as? String ?? "end_turn"
        let stopReason = parseStopReason(stopReasonStr)
        events.append(.turnEnded(stopReason))

        return events
    }

    // MARK: - Parsing Helpers

    private func parseUsage(usage: [String: Any], model: String?, costUSD: Double? = nil) -> Usage {
        let details = usage["output_tokens_details"] as? [String: Any]
        return Usage(
            model: model,
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int,
            thinkingTokens: details?["thinking_tokens"] as? Int,
            costUSD: costUSD
        )
    }

    /// A file-editing tool's input, as a diff the UI can render (FR-20).
    ///
    /// Returns nil for every other tool: a tool call without an edit renders as a plain call, and
    /// guessing an edit out of an unknown input shape would render a wrong diff.
    private func fileEdit(toolName: String, input: [String: Any]) -> FileEdit? {
        guard let path = input["file_path"] as? String else { return nil }
        switch toolName {
        case "Write":
            return FileEdit(path: path, oldText: nil, newText: input["content"] as? String)
        case "Edit":
            // TODO(B11): unverified — Write's shape comes from a capture, Edit's does not.
            // Confirm old_string/new_string against a real capture before trusting the diff.
            return FileEdit(
                path: path,
                oldText: input["old_string"] as? String,
                newText: input["new_string"] as? String
            )
        default:
            return nil
        }
    }

    private func parseStopReason(_ reason: String) -> StopReason {
        switch reason {
        case "end_turn":
            return .endTurn
        case "max_tokens":
            return .maxTokens
        case "tool_use":
            // Tool use is normal flow, not a stop reason in our model
            return .endTurn
        default:
            return .endTurn
        }
    }
}
