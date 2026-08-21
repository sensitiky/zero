import Foundation

/// Encodes Zero commands into Codex app-server JSON-RPC 2.0 messages.
///
/// Codex is a bidirectional JSON-RPC 2.0 protocol: we send requests and handle inbound requests
/// from the server. This encoder produces the outbound records.
public struct CodexEncoder: ProtocolEncoder {
    /// Counter for allocating unique request ids.
    private var nextID = 1

    /// The current thread id, if a thread is active.
    /// ponytail: stored after thread/start succeeds; needed for turn/start.
    private var threadID: String?

    /// The current turn id, if a turn is in progress.
    private var turnID: String?

    public init() {}

    public mutating func encodePrompt(_ text: String) throws -> [Data] {
        // TODO(B5): Should prompts create a new thread (thread/start) or continue an existing one
        // (thread/resume)? Currently assumes thread/start. If threads persist across sessions,
        // this should be parameterized or inferred from state.

        let threadStart = encodeRequest(
            method: "thread/start",
            params: [
                "model": "codex-4o", // TODO(B5): Should this be configurable?
                "reasoningEffort": "medium",
            ]
        )

        let turnStart = encodeRequest(
            method: "turn/start",
            params: [
                "threadId": threadID ?? "thr_auto",
                "input": [
                    [
                        "type": "text",
                        "text": text,
                    ]
                ],
            ]
        )

        return [threadStart, turnStart]
    }

    public mutating func encodePermissionResponse(
        requestID: String,
        optionID: String,
        origin: PermissionOrigin
    ) throws -> [Data] {
        // Respond to server's approval request with the same id.
        // The decision value comes from optionID, which should be one of:
        // "accept", "acceptForSession", "decline", "cancel".
        let response: [String: Any] = [
            "id": requestID,
            "result": [
                "decision": optionID,
            ],
        ]

        let json = try JSONSerialization.data(
            withJSONObject: response,
            options: .sortedKeys
        )

        return [json]
    }

    public mutating func encodeCancel() throws -> [Data]? {
        // Send turn/interrupt to cancel the current turn.
        // TODO(B5): Should this be parameterized with threadId and turnId from session state?
        // Currently uses placeholder ids; a real implementation would track these.
        guard let threadID = threadID, let turnID = turnID else {
            return nil
        }

        let cancel = encodeRequest(
            method: "turn/interrupt",
            params: [
                "threadId": threadID,
                "turnId": turnID,
            ]
        )

        return [cancel]
    }

    // MARK: - Helpers

    private mutating func encodeRequest(method: String, params: [String: Any]) -> Data {
        let id = String(nextID)
        nextID += 1

        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]

        // Safe force unwrap: JSONSerialization only fails on non-serializable types.
        return try! JSONSerialization.data(
            withJSONObject: request,
            options: .sortedKeys
        )
    }
}
