import Foundation

/// Encodes messages to send to an Agent Client Protocol (ACP) v1 agent.
///
/// ACP is JSON-RPC 2.0 over stdio. The encoder generates properly-formed requests and
/// notifications, managing request IDs for correlation.
public struct ACPEncoder: ProtocolEncoder {
    private var nextRequestID: Int = 1

    public init() {}

    // MARK: - ProtocolEncoder Conformance

    public mutating func encodePrompt(_ text: String) throws -> [Data] {
        let requestID = nextRequestID
        nextRequestID += 1

        let contentBlock: [String: Any] = [
            "type": "text",
            "text": text,
        ]

        let params: [String: Any] = [
            "sessionId": "TODO", // TODO(B6): sessionId should be passed in, not hardcoded
            "prompt": [contentBlock],
        ]

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "session/prompt",
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        return [data]
    }

    public mutating func encodePermissionResponse(
        requestID: String,
        optionID: String,
        origin: PermissionOrigin
    ) throws -> [Data] {
        guard let reqID = Int(requestID) else {
            throw DecoderError("Invalid request ID: \(requestID)")
        }

        let outcome: [String: Any] = [
            "outcome": "selected",
            "optionId": optionID,
        ]

        let result: [String: Any] = [
            "outcome": outcome,
        ]

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqID,
            "result": result,
        ]

        let data = try JSONSerialization.data(withJSONObject: response)
        return [data]
    }

    public mutating func encodeCancel() throws -> [Data]? {
        // ACP supports session/cancel as a notification
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": [
                "sessionId": "TODO", // TODO(B6): sessionId should be passed in
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: notification)
        return [data]
    }

    // MARK: - Additional Encoding Methods

    /// Encodes the initialize request that starts an ACP session.
    ///
    /// Must be called once before any other requests. Returns the serialized JSON-RPC request.
    /// - Parameters:
    ///   - clientInfo: Information about the client (name, version)
    ///   - capabilities: Client capabilities advertised to the agent
    /// - Returns: Array of Data records (typically one)
    public mutating func encodeInitialize(
        clientInfo: (name: String, version: String)?,
        capabilities: ClientCapabilities
    ) throws -> [Data] {
        let requestID = nextRequestID
        nextRequestID += 1

        var clientInfoObj: [String: Any]?
        if let info = clientInfo {
            clientInfoObj = [
                "name": info.name,
                "version": info.version,
            ]
        }

        var params: [String: Any] = [
            "protocolVersion": "1.0",
            "clientCapabilities": encodeClientCapabilities(capabilities),
        ]

        if let info = clientInfoObj {
            params["clientInfo"] = info
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "initialize",
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        return [data]
    }

    /// Encodes a session/new request to create a new conversation.
    ///
    /// - Parameters:
    ///   - cwd: Working directory (absolute path)
    ///   - mcpServers: Array of MCP servers to connect
    /// - Returns: Array of Data records
    public mutating func encodeSessionNew(
        cwd: String,
        mcpServers: [[String: Any]]
    ) throws -> [Data] {
        let requestID = nextRequestID
        nextRequestID += 1

        let params: [String: Any] = [
            "cwd": cwd,
            "mcpServers": mcpServers,
        ]

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "session/new",
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        return [data]
    }

    // MARK: - Private Helpers

    private func encodeClientCapabilities(_ capabilities: ClientCapabilities) -> [String: Any] {
        return [
            "fs": [
                "readTextFile": false,
                "writeTextFile": false,
            ],
            "terminal": false,
            "auth": [
                "terminal": false,
            ],
        ]
    }
}

// TODO(B6): Define or import ClientCapabilities type if it doesn't exist
public struct ClientCapabilities: Sendable {
    public init() {}
}
