import Darwin
import Foundation

/// Wire format for the hook helper to request a permission decision.
///
/// Public because the helper is a separate module: both sides of the socket must agree on these
/// shapes by construction, not by two copies staying in sync.
public struct HookRequest: Sendable, Codable {
    public var toolName: String
    /// The tool input as JSON. Opaque data for rendering — never interpreted, never executed.
    public var toolInput: String
    public var requestID: String
    public var sessionID: String
    public var cwd: String
    /// Recorded for the log; it must never influence a decision.
    public var permissionMode: String

    /// Claude Code sends the hook payload in snake_case on stdin. Note the asymmetry with
    /// `HookResponse`, which it reads back in camelCase — that asymmetry is verified against
    /// 2.1.237 and is exactly why neither side may be guessed.
    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case requestID = "request_id"
        case sessionID = "session_id"
        case cwd
        case permissionMode = "permission_mode"
    }

    public init(
        toolName: String,
        toolInput: String,
        requestID: String,
        sessionID: String,
        cwd: String,
        permissionMode: String
    ) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.requestID = requestID
        self.sessionID = sessionID
        self.cwd = cwd
        self.permissionMode = permissionMode
    }
}

/// What Claude Code reads on the hook's stdout to decide whether the tool call proceeds.
///
/// **The key names are camelCase and must stay that way.** Verified against Claude Code 2.1.237:
/// a `deny` in this shape blocks a `Write` even under `--permission-mode acceptEdits`. Rename a key
/// and the CLI stops recognizing the response — which means the tool call proceeds. Getting this
/// wrong turns the whole permission system into a no-op that still looks like it works.
public struct HookResponse: Sendable, Codable {
    public enum Decision: String, Sendable, Codable {
        case allow
        case deny
    }

    public struct HookOutput: Sendable, Codable {
        public var hookEventName: String = "PreToolUse"
        public var permissionDecision: Decision
        public var permissionDecisionReason: String

        public init(permissionDecision: Decision, permissionDecisionReason: String) {
            self.permissionDecision = permissionDecision
            self.permissionDecisionReason = permissionDecisionReason
        }
    }

    public var hookSpecificOutput: HookOutput

    public init(decision: Decision, reason: String) {
        self.hookSpecificOutput = HookOutput(
            permissionDecision: decision,
            permissionDecisionReason: reason
        )
    }

    /// The bytes to print on stdout. Falls back to a literal deny, because a serialization failure
    /// must not become an approval.
    public func stdoutPayload() -> Data {
        (try? JSONEncoder().encode(self))
            ?? Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Zero: encoding failure"}}"#.utf8)
    }
}

/// Length-prefixed framing and blocking unix-socket I/O, shared by both sides.
public enum SocketIO {
    public static let headerSize = 4
    /// A request is a tool name plus its input; a megabyte is generous and bounds a hostile peer.
    public static let maxPayloadBytes = 1 << 20
    /// `sun_path` on Darwin. Exposed so callers can size their directories against it instead of
    /// discovering the limit as a bind failure.
    public static let maxSocketPathBytes = 104

    public static func encode(_ payload: Data) -> Data {
        var framed = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        framed.append(payload)
        return framed
    }

    /// Splits one frame off the front of `buffer`, or nil if it is not yet complete.
    ///
    /// Every index is taken relative to `startIndex`, and both returned values are rebased through
    /// `Data.init`. A `Data` slice keeps the parent's indices, so absolute offsets crash the moment
    /// a caller feeds back the remainder of a previous frame — which is the normal case when two
    /// frames arrive in one read.
    public static func decode(_ buffer: Data) -> (payload: Data, remaining: Data)? {
        guard buffer.count >= headerSize else { return nil }
        let start = buffer.startIndex
        let length = Int(
            buffer[start..<(start + headerSize)].withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            }
        )
        guard length <= maxPayloadBytes else { return nil }
        let total = headerSize + length
        guard buffer.count >= total else { return nil }
        return (
            Data(buffer[(start + headerSize)..<(start + total)]),
            Data(buffer[(start + total)...])
        )
    }

    /// Fills a `sockaddr_un` for `path`.
    ///
    /// The copy happens inside the `withCString` closure on purpose: carrying that pointer out is
    /// undefined behavior, and the memory is gone by the time anything reads it.
    public static func address(path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < min(capacity, maxSocketPathBytes) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withCString { src in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, capacity)
            }
        }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    /// Connects to a listening unix socket. Returns nil rather than throwing: every caller here
    /// treats failure as deny, and an error type would only be unwrapped to the same thing.
    public static func connect(path: String, timeout: TimeInterval) -> Int32? {
        guard let resolved = address(path: path) else { return nil }
        var addr = resolved.0
        let len = resolved.1
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setTimeouts(fd, timeout)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        guard connected >= 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Bounds a blocking read or write so a peer that stops talking cannot hang us forever.
    public static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    public static func writeFrame(_ fd: Int32, _ payload: Data) -> Bool {
        let remaining = [UInt8](encode(payload))
        var offset = 0
        while offset < remaining.count {
            let written = remaining[offset...].withUnsafeBufferPointer {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Reads exactly one frame. Returns nil on timeout, EOF, a malformed header, or an oversize claim.
    public static func readFrame(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let (payload, _) = decode(buffer) { return payload }
            let read = chunk.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            guard read > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<read])
            guard buffer.count <= maxPayloadBytes + headerSize else { return nil }
        }
    }
}
