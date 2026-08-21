import Foundation

// The Claude Code hook helper. Runs before each tool call to request permission from the app.
// Reads the hook JSON from stdin, connects to the session socket, forwards the request,
// and writes the response to stdout. Fails closed on any error.

do {
    // Read the hook JSON from stdin.
    guard let hookInput = readStdin() else {
        denyAndExit(reason: "Failed to read stdin")
    }

    guard let hookData = hookInput.data(using: .utf8) else {
        denyAndExit(reason: "Invalid UTF-8 in hook input")
    }

    // Parse the hook JSON to extract the fields we need.
    guard let json = try? JSONSerialization.jsonObject(with: hookData) as? [String: Any] else {
        denyAndExit(reason: "Failed to parse hook input as JSON")
    }

    guard
        let toolName = json["tool_name"] as? String,
        let toolInput = json["tool_input"] as? String,
        let sessionID = json["session_id"] as? String,
        let requestID = json["request_id"] as? String,
        let cwd = json["cwd"] as? String,
        let permissionMode = json["permission_mode"] as? String
    else {
        denyAndExit(reason: "Missing required fields in hook input")
    }

    // Build the socket path.
    let socketPath = try getSocketPath(for: sessionID)

    // Connect to the socket and ask for a decision.
    let decision = try askBroker(
        toolName: toolName,
        toolInput: toolInput,
        requestID: requestID,
        sessionID: sessionID,
        cwd: cwd,
        permissionMode: permissionMode,
        socketPath: socketPath
    )

    // Build and print the response.
    let response = buildResponse(decision: decision)
    guard let responseJSON = try? JSONSerialization.data(withJSONObject: response) else {
        denyAndExit(reason: "Failed to encode response")
    }

    guard let responseString = String(data: responseJSON, encoding: .utf8) else {
        denyAndExit(reason: "Failed to convert response to string")
    }

    print(responseString, terminator: "")
    exit(0)
} catch {
    denyAndExit(reason: String(describing: error))
}

func getSocketPath(for sessionID: String) throws -> String {
    let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )

    let socketDir = appSupport.appendingPathComponent("tech.incu.zero/permissions/hooks")
    let socketPath = socketDir.appendingPathComponent("\(sessionID).sock").path
    return socketPath
}

func askBroker(
    toolName: String,
    toolInput: String,
    requestID: String,
    sessionID: String,
    cwd: String,
    permissionMode: String,
    socketPath: String
) throws -> String {
    // Create the request JSON.
    let request: [String: Any] = [
        "tool_name": toolName,
        "tool_input": toolInput,
        "request_id": requestID,
        "session_id": sessionID,
        "cwd": cwd,
        "permission_mode": permissionMode,
    ]

    guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
        throw HelperError.requestEncodingFailed
    }

    // Connect to the socket with a timeout.
    let socket = try connectToSocket(at: socketPath, timeout: 5.0)
    defer { Darwin.close(socket) }

    // Send the framed request.
    let framed = SocketFrame.encode(requestData)
    let written = framed.withUnsafeBytes { ptr in
        Darwin.write(socket, ptr.baseAddress!, framed.count)
    }

    guard written == framed.count else {
        throw HelperError.sendFailed
    }

    // Read the response with a timeout.
    guard let response = try readFramedResponse(from: socket, timeout: 30.0) else {
        throw HelperError.responseReadTimeout
    }

    // Decode the response to extract the decision.
    guard let responseJSON = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
          let hookOutput = responseJSON["hookSpecificOutput"] as? [String: Any],
          let decision = hookOutput["permission_decision"] as? String
    else {
        throw HelperError.responseMalformed
    }

    return decision
}

func connectToSocket(at path: String, timeout: TimeInterval) throws -> Int32 {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else {
        throw HelperError.socketCreationFailed
    }

    // Set a connection timeout by using setsockopt SO_SNDTIMEO.
    var tv = timeval()
    tv.tv_sec = time_t(timeout)
    tv.tv_usec = Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)

    _ = Darwin.setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Connect to the socket.
    var socketAddr = sockaddr_un()
    socketAddr.sun_family = sa_family_t(AF_UNIX)

    let pathCString = path.withCString { $0 }
    let maxLen = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
    memcpy(&socketAddr.sun_path, pathCString, min(path.count, maxLen))

    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: socketAddr) { addr in
        Darwin.connect(
            socket,
            UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr.self),
            len
        )
    }

    guard result >= 0 else {
        Darwin.close(socket)
        throw HelperError.connectionFailed
    }

    return socket
}

func readFramedResponse(from fd: Int32, timeout: TimeInterval) throws -> Data? {
    var buffer = Data()

    // Set a read timeout.
    var tv = timeval()
    tv.tv_sec = time_t(timeout)
    tv.tv_usec = Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)

    guard Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) >= 0 else {
        throw HelperError.socketConfigFailed
    }

    let bufferSize = 4096
    var readBuffer = [UInt8](repeating: 0, count: bufferSize)

    while true {
        let nread = Darwin.read(fd, &readBuffer, bufferSize)
        if nread < 0 {
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK {
                return nil // Timeout
            }
            throw HelperError.readFailed
        }

        if nread == 0 {
            return nil // Connection closed
        }

        buffer.append(readBuffer, count: nread)

        // Check if we have a complete frame.
        if let (payload, _) = SocketFrame.decode(buffer) {
            return payload
        }
    }
}

func buildResponse(decision: String) -> [String: Any] {
    let hookDecision = decision == "allow" ? "allow" : "deny"
    let reason = decision == "allow" ? "User approved" : "User denied"

    return [
        "hookSpecificOutput": [
            "hook_event_name": "PreToolUse",
            "permission_decision": hookDecision,
            "permission_decision_reason": reason,
        ] as [String: Any]
    ]
}

struct SocketFrame {
    static let headerSize = 4

    static func encode(_ json: Data) -> Data {
        let length = UInt32(json.count).bigEndian
        var framed = Data(withUnsafeBytes(of: length) { Data($0) })
        framed.append(json)
        return framed
    }

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

enum HelperError: Error {
    case socketCreationFailed
    case socketConfigFailed
    case connectionFailed
    case sendFailed
    case readFailed
    case responseReadTimeout
    case requestEncodingFailed
    case responseMalformed
}

func denyAndExit(reason: String) -> Never {
    let response: [String: Any] = [
        "hookSpecificOutput": [
            "hook_event_name": "PreToolUse",
            "permission_decision": "deny",
            "permission_decision_reason": reason,
        ] as [String: Any]
    ]

    if let data = try? JSONSerialization.data(withJSONObject: response),
       let json = String(data: data, encoding: .utf8)
    {
        print(json, terminator: "")
    }

    exit(0)
}

func readStdin() -> String? {
    var input = ""
    while let line = readLine() {
        input += line
    }
    return input.isEmpty ? nil : input
}
