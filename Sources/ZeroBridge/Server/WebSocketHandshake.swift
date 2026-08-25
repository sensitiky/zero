import CryptoKit
import Foundation

/// The RFC 6455 opening handshake, and nothing more.
///
/// One `NWListener` serves both protocols (FR-1): a request carrying `Upgrade: websocket` completes
/// the handshake and that connection switches to frame mode, every other request is served as plain
/// HTTP. Deciding which is which is this file's whole job, so the decision is testable without a
/// socket.
public enum WebSocketHandshake {

    /// RFC 6455 §1.3. The one magic constant in the protocol.
    static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// The only version this speaks, and the only one any browser or React Native client sends.
    static let version = "13"

    public enum Failure: Error, Sendable, Equatable {
        /// The request did not ask for an upgrade at all — it is an ordinary HTTP request.
        case notAnUpgrade
        case unsupportedMethod
        case missingKey
        case unsupportedVersion(String?)

        /// What the client is told. A failed handshake is a failed request, in the contract's
        /// error shape like every other one.
        public var response: HTTPResponse {
            switch self {
            case .notAnUpgrade, .unsupportedMethod, .missingKey:
                HTTPResponse.error(.badRequest("Not a valid WebSocket upgrade request."))
            case .unsupportedVersion:
                // 426 carries the version the server does speak, which is the one thing that makes
                // this failure actionable.
                HTTPResponse(
                    status: 426,
                    headers: [
                        (name: "Content-Type", value: "application/json; charset=utf-8"),
                        (name: "Sec-WebSocket-Version", value: version),
                    ],
                    body: (try? BridgeJSON.encode(
                        ErrorBody(
                            error: "bad_request",
                            message: "This server speaks WebSocket version 13 only."
                        )
                    )) ?? Data(),
                    closeConnection: true
                )
            }
        }
    }

    /// Whether this request is asking to become a WebSocket.
    ///
    /// `Connection` is a comma-separated list (`keep-alive, Upgrade` is what several clients send),
    /// so it is matched as a list and not compared whole.
    public static func isUpgrade(_ request: HTTPRequest) -> Bool {
        guard let upgrade = request.headers["upgrade"] else { return false }
        return upgrade.lowercased() == "websocket"
            && request.headers.lists("upgrade", in: "connection")
    }

    /// `Sec-WebSocket-Accept`: base64(SHA-1(key + magic)).
    ///
    /// SHA-1 is what RFC 6455 specifies. It is not a security primitive here — it proves the peer
    /// read the request, nothing else — which is why `CryptoKit.Insecure` is the right spelling and
    /// why it is safe to use one.
    public static func accept(forKey key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The `101` for a valid upgrade, or a typed failure.
    ///
    /// Pairing is **not** checked here: it is checked by the router before this is reached, because
    /// a wrong code must close without upgrading (FR-4), and a handshake that succeeded and then
    /// closed is a handshake that leaked "the path exists".
    public static func response(for request: HTTPRequest) throws -> HTTPResponse {
        guard isUpgrade(request) else { throw Failure.notAnUpgrade }
        guard request.method.uppercased() == "GET" else { throw Failure.unsupportedMethod }

        let rawVersion = request.headers["sec-websocket-version"]?
            .trimmingCharacters(in: .whitespaces)
        guard rawVersion == version else { throw Failure.unsupportedVersion(rawVersion) }

        guard let key = request.headers["sec-websocket-key"]?
            .trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw Failure.missingKey
        }

        return HTTPResponse(
            status: 101,
            headers: [
                (name: "Upgrade", value: "websocket"),
                (name: "Connection", value: "Upgrade"),
                (name: "Sec-WebSocket-Accept", value: accept(forKey: key)),
            ],
            body: Data(),
            closeConnection: false
        )
    }
}
