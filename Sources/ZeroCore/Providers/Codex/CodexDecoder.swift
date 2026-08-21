import Foundation

/// Decodes Codex app-server JSON-RPC 2.0 notifications and responses into AgentEvent.
///
/// Codex speaks bidirectional JSON-RPC 2.0 over newline-delimited JSON, omitting the
/// `"jsonrpc":"2.0"` member on the wire. Notifications (no `id`) stream events; requests with `id`
/// require responses. The decoder maintains state for JSON-RPC correlation (approvals).
public struct CodexDecoder: ProtocolDecoder {
    /// Pending approval requests, keyed by JSON-RPC id.
    private var pendingApprovals: [String: PendingApproval] = [:]

    /// In-flight tool call states, keyed by item id.
    /// ponytail: tracks call status across item/started → item/completed lifecycle.
    private var toolCalls: [String: ToolCall] = [:]

    private struct PendingApproval: Sendable {
        let toolName: String
        let detail: String
        let options: [PermissionOption]
    }

    public init() {}

    public mutating func decode(line: Data) -> [AgentEvent] {
        // Parse JSON. On error, return unrecognized and continue.
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return [.unrecognized(raw: line)]
        }

        // Determine message type: notification (no id), response (id + result/error), or request (id + method).
        let id = json["id"] as? String
        let method = json["method"] as? String

        switch (id, method, json["result"], json["error"]) {
        case (nil, let m?, _, _):
            // Notification (no id).
            return decodeNotification(method: m, params: json["params"] as? [String: Any])
        case (let id?, nil, let result?, nil):
            // Response to a request we sent (result present).
            return decodeResponse(id: id, result: result)
        case (let id?, nil, nil, let error?):
            // Error response to a request we sent.
            return decodeErrorResponse(id: id, error: error)
        case (let id?, let m?, _, nil):
            // Server request with id (bidirectional RPC): approval, etc.
            return decodeServerRequest(id: id, method: m, params: json["params"] as? [String: Any])
        default:
            // Unrecognized structure.
            return [.unrecognized(raw: line)]
        }
    }

    // MARK: - Notification Decoding

    private mutating func decodeNotification(method: String, params: [String: Any]?) -> [AgentEvent] {
        switch method {
        case "turn/started":
            return decodeTurnStarted(params: params)
        case "turn/completed":
            return decodeTurnCompleted(params: params)
        case "item/started":
            return decodeItemStarted(params: params)
        case "item/completed":
            return decodeItemCompleted(params: params)
        case "item/agentMessage/delta":
            return decodeAgentMessageDelta(params: params)
        case "item/reasoning/textDelta":
            return decodeReasoningTextDelta(params: params)
        case "item/reasoning/summaryTextDelta":
            return decodeReasoningSummaryDelta(params: params)
        default:
            // Unknown notification method.
            // ponytail: pass through to preserve visibility of new event types added by the server.
            let unrecognized = (try? JSONSerialization.data(
                withJSONObject: ["method": method, "params": params as Any],
                options: .sortedKeys
            )) ?? Data()
            return [.unrecognized(raw: unrecognized)]
        }
    }

    private func decodeTurnStarted(params: [String: Any]?) -> [AgentEvent] {
        // turn/started nominally signals a new turn, but doesn't directly produce an event
        // in the Zero model. Turns are implicit in the turn/completed stop reason.
        // TODO(B5): Clarify whether turn/started should produce .turnStarted(id:) event.
        // For now, suppress it to avoid spurious events.
        return []
    }

    private func decodeTurnCompleted(params: [String: Any]?) -> [AgentEvent] {
        guard let turn = params?["turn"] as? [String: Any],
              let stopReason = turn["stopReason"] as? String else {
            return []
        }

        var events: [AgentEvent] = []

        // Determine stop reason.
        let stop = decodeStopReason(stopReason)
        events.append(.turnEnded(stop))

        // Extract usage if present.
        if let usage = params?["usage"] as? [String: Any] {
            events.append(contentsOf: decodeUsage(usage))
        }

        return events
    }

    private mutating func decodeItemStarted(params: [String: Any]?) -> [AgentEvent] {
        guard let item = params?["item"] as? [String: Any],
              let itemId = item["id"] as? String,
              let itemType = item["type"] as? String else {
            return []
        }

        // Pre-allocate tool call state if this is a tool call item.
        // TODO(B5): Clarify whether a tool call can span multiple items or is always atomic.
        if itemType == "mcpToolCall" {
            let toolName = item["tool"] as? String ?? "unknown"
            let inputJSON = item["arguments"] as? String ?? "{}"
            toolCalls[itemId] = ToolCall(
                id: itemId,
                name: toolName,
                input: inputJSON,
                status: .pending
            )
        }

        return []
    }

    private mutating func decodeItemCompleted(params: [String: Any]?) -> [AgentEvent] {
        guard let item = params?["item"] as? [String: Any],
              let itemId = item["id"] as? String,
              let itemType = item["type"] as? String else {
            return []
        }

        var events: [AgentEvent] = []

        switch itemType {
        case "agentMessage":
            // Agent message completion. Extract text and optional edit.
            // TODO(B5): Clarify whether file edits appear as separate item type or embedded in agentMessage.
            let _ = item["text"] as? String ?? ""
            // Track for potential later use (e.g., detecting file edit patterns in text).
            break

        case "mcpToolCall", "commandExecution":
            // Tool call completion: determine status and emit event.
            if let toolCall = toolCalls[itemId] {
                var call = toolCall
                let status = item["status"] as? String ?? "pending"
                let result = item["result"] as? String
                let exitCode = item["exitCode"] as? Int

                call.status = decodeToolCallStatus(status, exitCode: exitCode, result: result)
                call.output = result
                call.endedAt = Date()

                events.append(.toolCall(call))
                toolCalls.removeValue(forKey: itemId)
            }

        case "fileChange":
            // File change item: extract diff if present.
            // TODO(B5): Clarify exact structure of fileChange items and whether they produce toolCall or separate event.
            if let changes = item["changes"] as? [[String: Any]] {
                for change in changes {
                    if let path = change["path"] as? String {
                        var call = ToolCall(
                            id: itemId,
                            name: "edit",
                            input: path,
                            status: .succeeded
                        )
                        if let oldText = change["oldText"] as? String,
                           let newText = change["newText"] as? String {
                            call.edit = FileEdit(path: path, oldText: oldText, newText: newText)
                        }
                        events.append(.toolCall(call))
                    }
                }
            }

        default:
            break
        }

        return events
    }

    private func decodeAgentMessageDelta(params: [String: Any]?) -> [AgentEvent] {
        guard let text = params?["text"] as? String else {
            return []
        }
        return [.textDelta(text)]
    }

    private func decodeReasoningTextDelta(params: [String: Any]?) -> [AgentEvent] {
        guard let text = params?["text"] as? String else {
            return []
        }
        // Map reasoning text to thinkingDelta: reasoning is the model's internal thought process.
        return [.thinkingDelta(text)]
    }

    private func decodeReasoningSummaryDelta(params: [String: Any]?) -> [AgentEvent] {
        // Summary deltas are also thinking/reasoning preview.
        guard let text = params?["text"] as? String else {
            return []
        }
        return [.thinkingDelta(text)]
    }

    // MARK: - Response and Request Decoding

    private mutating func decodeResponse(id: String, result: Any) -> [AgentEvent] {
        // Response to a request we sent. Currently, we don't wait for responses,
        // so this is unexpected. Return unrecognized.
        // TODO(B5): If Zero sends requests (e.g., thread/start), handle responses here.
        return []
    }

    private func decodeErrorResponse(id: String, error: Any) -> [AgentEvent] {
        // Error response to a request we sent.
        if let errorDict = error as? [String: Any],
           let message = errorDict["message"] as? String {
            return [.failed(reason: "RPC error: \(message)")]
        }
        return [.failed(reason: "RPC error")]
    }

    private mutating func decodeServerRequest(id: String, method: String, params: [String: Any]?) -> [AgentEvent] {
        switch method {
        case "execCommandApproval", "applyPatchApproval":
            return decodeApprovalRequest(id: id, method: method, params: params)
        default:
            let unrecognized = (try? JSONSerialization.data(
                withJSONObject: ["id": id, "method": method, "params": params as Any],
                options: .sortedKeys
            )) ?? Data()
            return [.unrecognized(raw: unrecognized)]
        }
    }

    private mutating func decodeApprovalRequest(id: String, method: String, params: [String: Any]?) -> [AgentEvent] {
        // Extract approval details.
        // TODO(B5): Confirm exact structure of execCommandApproval vs applyPatchApproval.
        let command = params?["command"] as? String ?? ""
        let reason = params?["reason"] as? String ?? ""
        let detail = reason.isEmpty ? command : "\(command)\n\nReason: \(reason)"

        let toolName = method == "applyPatchApproval" ? "applyPatch" : "execCommand"

        // Standard approval options.
        let options: [PermissionOption] = [
            .init(id: "accept", kind: .allowOnce, label: "Allow once"),
            .init(id: "acceptForSession", kind: .allowAlways, label: "Allow for session"),
            .init(id: "decline", kind: .denyOnce, label: "Deny once"),
            .init(id: "cancel", kind: .denyAlways, label: "Cancel"),
        ]

        // Track for later correlation when response is sent.
        pendingApprovals[id] = PendingApproval(toolName: toolName, detail: detail, options: options)

        return [.permissionRequested(.init(
            id: id,
            toolName: toolName,
            detail: detail,
            options: options
        ))]
    }

    // MARK: - Helpers

    private func decodeStopReason(_ reason: String) -> StopReason {
        switch reason {
        case "endTurn":
            return .endTurn
        case "maxTokens":
            return .maxTokens
        case "cancelled", "cancel":
            return .cancelled
        case "refusal":
            return .refusal
        default:
            return .error(reason)
        }
    }

    private func decodeToolCallStatus(_ status: String, exitCode: Int?, result: String?) -> ToolCall.Status {
        switch status {
        case "pending":
            return .pending
        case "running":
            return .running
        case "succeeded":
            return .succeeded
        case "failed":
            let reason = result ?? "unknown error"
            return .failed(reason)
        case "denied":
            return .denied
        default:
            return .pending
        }
    }

    private func decodeUsage(_ usage: [String: Any]) -> [AgentEvent] {
        let u = Usage(
            inputTokens: usage["inputTokens"] as? Int,
            outputTokens: usage["outputTokens"] as? Int,
            cacheReadTokens: usage["cacheReadTokens"] as? Int,
            cacheWriteTokens: usage["cacheWriteTokens"] as? Int,
            contextWindowUsed: usage["contextWindowUsed"] as? Int,
            contextWindowTotal: usage["contextWindowTotal"] as? Int
        )
        return [.usage(u)]
    }
}
