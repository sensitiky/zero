import Foundation

/// Decodes Agent Client Protocol (ACP) v1 messages into normalized AgentEvent.
///
/// ACP is JSON-RPC 2.0 over stdio. The decoder handles both notifications (methods from the agent)
/// and responses to prior requests (identified by matching id).
public struct ACPDecoder: ProtocolDecoder {
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID: Int = 1

    enum PendingRequest {
        case sessionPrompt
    }

    public init() {}

    public mutating func decode(line: Data) -> [AgentEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            // Invalid JSON yields unrecognized, not an error
            return [.unrecognized(raw: line)]
        }

        // Handle JSON-RPC 2.0: check for method (notification) or result/error (response)
        if let method = json["method"] as? String {
            // Notification or request from agent
            return decodeNotification(method: method, params: json["params"], id: json["id"], raw: line)
        }

        if json["result"] != nil || json["error"] != nil {
            // Response to a prior request
            let id = json["id"] as? Int
            return decodeResponse(id: id, json: json, raw: line)
        }

        // Doesn't look like a valid JSON-RPC message
        return [.unrecognized(raw: line)]
    }

    // MARK: - Notification Decoding

    private func decodeNotification(method: String, params: Any?, id: Any?, raw: Data) -> [AgentEvent] {
        switch method {
        case "session/update":
            return decodeSessionUpdate(params: params, raw: raw)

        case "session/request_permission":
            return decodePermissionRequest(params: params, id: id, raw: raw)

        default:
            // Unknown method → unrecognized
            return [.unrecognized(raw: raw)]
        }
    }

    // MARK: - Session Update Decoding

    private func decodeSessionUpdate(params: Any?, raw: Data) -> [AgentEvent] {
        guard let params = params as? [String: Any],
              let update = params["update"] as? [String: Any],
              let sessionUpdate = update["sessionUpdate"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        switch sessionUpdate {
        case "agent_message_chunk":
            return decodeAgentMessageChunk(update: update, raw: raw)

        case "tool_call":
            return decodeToolCall(update: update, raw: raw)

        case "tool_call_update":
            return decodeToolCallUpdate(update: update, raw: raw)

        case "plan":
            return decodePlan(update: update, raw: raw)

        case "usage_update":
            return decodeUsageUpdate(update: update, raw: raw)

        case "current_mode_update":
            // Mode changes don't fit AgentEvent; keep as unrecognized
            return [.unrecognized(raw: raw)]

        default:
            return [.unrecognized(raw: raw)]
        }
    }

    private func decodeAgentMessageChunk(update: [String: Any], raw: Data) -> [AgentEvent] {
        guard let content = update["content"] as? [String: Any],
              let contentType = content["type"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        if contentType == "text", let text = content["text"] as? String {
            return [.textDelta(text)]
        }

        // Other content types in agent messages aren't mapped to AgentEvent types
        return [.unrecognized(raw: raw)]
    }

    private func decodeToolCall(update: [String: Any], raw: Data) -> [AgentEvent] {
        guard let toolCallId = update["toolCallId"] as? String,
              let title = update["title"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        let statusStr = update["status"] as? String ?? "pending"
        let status = parseToolStatus(statusStr)

        let toolCall = ToolCall(
            id: toolCallId,
            name: title,
            input: nil,
            output: nil,
            status: status
        )

        return [.toolCall(toolCall)]
    }

    private func decodeToolCallUpdate(update: [String: Any], raw: Data) -> [AgentEvent] {
        guard let toolCallId = update["toolCallId"] as? String else {
            return [.unrecognized(raw: raw)]
        }

        let statusStr = update["status"] as? String ?? "pending"
        let status = parseToolStatus(statusStr)

        // Check for file edits in content
        var edit: FileEdit?
        if let contentArray = update["content"] as? [[String: Any]] {
            for contentItem in contentArray {
                if contentItem["type"] as? String == "diff",
                   let path = contentItem["path"] as? String {
                    edit = FileEdit(
                        path: path,
                        oldText: contentItem["oldText"] as? String,
                        newText: contentItem["newText"] as? String
                    )
                    break
                }
            }
        }

        let toolCall = ToolCall(
            id: toolCallId,
            name: "", // Updates don't always provide the name
            input: nil,
            output: nil,
            status: status,
            edit: edit
        )

        return [.toolCall(toolCall)]
    }

    private func decodePlan(update: [String: Any], raw: Data) -> [AgentEvent] {
        guard let entries = update["entries"] as? [[String: Any]] else {
            return [.unrecognized(raw: raw)]
        }

        var planItems: [PlanItem] = []
        for (index, entry) in entries.enumerated() {
            guard let content = entry["content"] as? String,
                  let _ = entry["priority"] as? String,
                  let statusStr = entry["status"] as? String else {
                continue
            }

            let status: PlanItem.Status
            switch statusStr {
            case "pending":
                status = .pending
            case "in_progress":
                status = .inProgress
            case "completed":
                status = .completed
            default:
                status = .pending
            }

            let item = PlanItem(
                id: String(index),
                title: content,
                status: status
            )
            planItems.append(item)
        }

        return planItems.isEmpty ? [.unrecognized(raw: raw)] : [.plan(planItems)]
    }

    private func decodeUsageUpdate(update: [String: Any], raw: Data) -> [AgentEvent] {
        // Extract token counts from used/size fields
        let inputTokens = update["used"] as? Int
        let contextWindowUsed = update["used"] as? Int
        let contextWindowTotal = update["size"] as? Int

        let usage = Usage(
            model: nil,
            inputTokens: inputTokens,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            contextWindowUsed: contextWindowUsed,
            contextWindowTotal: contextWindowTotal
        )

        return [.usage(usage)]
    }

    // MARK: - Permission Request Decoding

    private func decodePermissionRequest(params: Any?, id: Any?, raw: Data) -> [AgentEvent] {
        guard let params = params as? [String: Any],
              let requestId = id as? Int else {
            return [.unrecognized(raw: raw)]
        }

        guard let toolCall = params["toolCall"] as? [String: Any],
              let toolCallId = toolCall["toolCallId"] as? String,
              let optionsArray = params["options"] as? [[String: Any]] else {
            return [.unrecognized(raw: raw)]
        }

        var options: [PermissionOption] = []
        for optionObj in optionsArray {
            guard let optionId = optionObj["optionId"] as? String,
                  let name = optionObj["name"] as? String,
                  let kindStr = optionObj["kind"] as? String else {
                continue
            }

            let kind = parsePermissionOptionKind(kindStr)
            let option = PermissionOption(id: optionId, kind: kind, label: name)
            options.append(option)
        }

        let permRequest = PermissionRequest(
            id: String(requestId),
            toolName: toolCallId,
            detail: "", // ACP doesn't provide detail in the request
            options: options
        )

        return [.permissionRequested(permRequest)]
    }

    // MARK: - Response Decoding

    private func decodeResponse(id: Int?, json: [String: Any], raw: Data) -> [AgentEvent] {
        guard id != nil else {
            return [.unrecognized(raw: raw)]
        }

        if let result = json["result"] as? [String: Any] {
            if let stopReason = result["stopReason"] as? String {
                let reason = parseStopReason(stopReason)
                return [.turnEnded(reason)]
            }
        }

        // Other response types not handled
        return [.unrecognized(raw: raw)]
    }

    // MARK: - Parsing Helpers

    private func parseToolStatus(_ status: String) -> ToolCall.Status {
        switch status {
        case "pending":
            return .pending
        case "in_progress":
            return .running
        case "completed":
            return .succeeded
        case "failed":
            return .failed("")
        case "cancelled":
            return .denied
        default:
            return .pending
        }
    }

    private func parsePermissionOptionKind(_ kind: String) -> PermissionOption.Kind {
        switch kind {
        case "allow_once":
            return .allowOnce
        case "allow_always":
            return .allowAlways
        case "reject_once":
            return .denyOnce
        case "reject_always":
            return .denyAlways
        default:
            return .denyOnce
        }
    }

    private func parseStopReason(_ reason: String) -> StopReason {
        switch reason {
        case "end_turn":
            return .endTurn
        case "max_tokens":
            return .maxTokens
        case "cancelled":
            return .cancelled
        case "refusal":
            return .refusal
        default:
            return .error(reason)
        }
    }
}
