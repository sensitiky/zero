import Foundation

/// Wire format for the hook helper to request a permission decision.
///
/// This structure is communicated between the helper and the broker as JSON over a unix domain socket.
struct HookRequest: Sendable, Codable {
    /// The tool being called.
    var toolName: String
    /// The tool input as JSON. Treated as opaque data for rendering; never interpreted or executed.
    var toolInput: String
    /// The provider's correlation id. The response must carry it back.
    var requestID: String
    /// The session this request belongs to. Used to route to the correct broker instance.
    var sessionID: String
    /// The working directory the tool would execute in.
    var cwd: String
    /// The permission mode Claude Code is running with (useful for logging; not used for decisions).
    var permissionMode: String

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case requestID = "request_id"
        case sessionID = "session_id"
        case cwd
        case permissionMode = "permission_mode"
    }
}

/// Wire format for the hook helper to receive a permission decision.
///
/// This is encoded as `{hookSpecificOutput: {...}}` and written to stdout for Claude Code.
struct HookResponse: Sendable, Codable {
    enum Decision: String, Codable {
        case allow
        case deny
    }

    var hookSpecificOutput: HookOutput

    struct HookOutput: Sendable, Codable {
        var hookEventName: String = "PreToolUse"
        var permissionDecision: Decision
        var permissionDecisionReason: String

        enum CodingKeys: String, CodingKey {
            case hookEventName = "hook_event_name"
            case permissionDecision = "permission_decision"
            case permissionDecisionReason = "permission_decision_reason"
        }
    }
}

/// Framing for socket communication between the helper and the broker.
///
/// Each message is framed as: 4-byte length (big-endian) + JSON payload.
/// This allows for atomic reads and writes without needing line delimiters.
struct SocketFrame: Sendable {
    static let headerSize = 4

    /// Encodes a JSON payload with a frame header.
    static func encode(_ json: Data) -> Data {
        let length = UInt32(json.count).bigEndian
        var framed = Data(withUnsafeBytes(of: length) { Data($0) })
        framed.append(json)
        return framed
    }

    /// Decodes a frame from a buffer. Returns (payload, remainingBuffer) or (nil, original) if incomplete.
    static func decode(_ buffer: Data) -> (payload: Data, remaining: Data)? {
        guard buffer.count >= Self.headerSize else {
            return nil
        }

        let lengthBytes = buffer.prefix(Self.headerSize)
        let length = lengthBytes.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }

        let fullMessageSize = Int(length) + Self.headerSize
        guard buffer.count >= fullMessageSize else {
            return nil
        }

        let payload = buffer.subdata(in: Self.headerSize..<fullMessageSize)
        let remaining = buffer.suffix(from: fullMessageSize)
        return (payload, remaining)
    }
}
