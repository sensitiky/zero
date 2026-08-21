import Foundation

/// Encodes messages to Claude Code (claude CLI) stream-json format.
///
/// Claude Code has no in-band permission channel or cancel mechanism in the stream,
/// so the encoder handles only prompt submission.
public struct ClaudeCodeEncoder: ProtocolEncoder {
    public init() {}

    public mutating func encodePrompt(_ text: String) throws -> [Data] {
        // Create a user message in the format the CLI expects via --input-format stream-json
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: message,
            options: []
        ) else {
            throw DecoderError("Failed to encode prompt message")
        }

        // Add newline for NDJSON format
        var record = jsonData
        record.append(0x0A) // '\n'

        return [record]
    }

    public mutating func encodePermissionResponse(
        requestID: String,
        optionID: String,
        origin: PermissionOrigin
    ) throws -> [Data] {
        // Claude Code 2.1.237 has no in-band permission channel. The protocol runs in
        // --permission-mode headless (denies everything) or default (prompts the user directly
        // in the CLI). Zero cannot intercept these prompts through the wire protocol.
        // See PROVENANCE.md: control_request and can_use_tool do not exist on the wire.
        // This is an open design question (FR-23), not a bug.
        //
        // Return nil to signal that the provider has no mechanism for permission responses.
        throw DecoderError("Claude Code has no in-band permission channel")
    }

    public mutating func encodeCancel() throws -> [Data]? {
        // Claude Code has no cancel record in stream-json, so the caller must fall back to
        // `AgentProcess.interrupt()` — SIGINT, which ends the turn. Not SIGTERM or SIGKILL: those
        // tear down the process tree and lose the session, which is a different operation than
        // cancelling a turn.
        return nil
    }
}
