import Foundation

/// Translates one provider's wire records into `AgentEvent`.
///
/// Deliberately synchronous and free of I/O: a decoder is fed lines and returns events, which is
/// what makes it testable against recorded fixtures without a live agent or an account. Everything
/// stateful about a protocol — request/response correlation, in-flight tool calls — lives in the
/// conforming type.
public protocol ProtocolDecoder: Sendable {
    /// Decodes one NDJSON record.
    ///
    /// Must not throw. A malformed or unknown record yields `.unrecognized` so one bad line cannot
    /// end a session that is otherwise healthy (FR-16).
    mutating func decode(line: Data) -> [AgentEvent]
}

/// Encodes what Zero sends back to a provider.
public protocol ProtocolEncoder: Sendable {
    /// The records that start a turn with `text`.
    mutating func encodePrompt(_ text: String) throws -> [Data]

    /// The records that answer a pending permission request.
    ///
    /// `origin` is required rather than informational: see `PermissionOrigin`.
    mutating func encodePermissionResponse(
        requestID: String,
        optionID: String,
        origin: PermissionOrigin
    ) throws -> [Data]

    /// The records that cancel the current turn without ending the session (FR-15).
    /// `nil` means the provider has no in-band cancel and the caller must fall back to signalling.
    mutating func encodeCancel() throws -> [Data]?
}

public struct DecoderError: Error, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
