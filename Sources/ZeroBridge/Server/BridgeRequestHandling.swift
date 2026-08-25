import Foundation

/// What a connection asks when a client tries to open a WebSocket.
public enum BridgeSubscription: Sendable {
    /// Refused **before** the handshake: the connection is answered as plain HTTP and closed.
    ///
    /// This is what a wrong or missing pairing code gets (FR-4: "a WebSocket is closed without
    /// upgrading"). Upgrading and then closing would already have said "this path exists".
    case reject(HTTPResponse)
    /// The handshake completes and the socket then closes with a code — an unknown session id,
    /// which CONTRACT.md places after the handshake.
    case closeAfterUpgrade(WebSocketCloseCode, String)
    /// Subscribed. `initial` is written before anything else can be, which is what makes
    /// `session.snapshot` the first frame (FR-20).
    case accept(topic: EventHub.Topic, initial: [BridgeEvent])
}

/// The one thing `BridgeServer` needs from the layer above it.
///
/// The server knows about bytes, sockets and frames; it knows nothing about paths, pairing or
/// sessions. `BridgeRouter` (Phase D) is the only production conformer, and a fake one is what lets
/// every endpoint be tested without a socket and the socket be tested without the app.
public protocol BridgeRequestHandling: Sendable {
    func respond(to request: HTTPRequest) async -> HTTPResponse
    func subscribe(to request: HTTPRequest) async -> BridgeSubscription
}
