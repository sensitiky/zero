import Foundation
import Testing

@testable import ZeroBridge

/// FR-1: one listener, two protocols. These are the bytes that decide which.
@Suite("WebSocketHandshake")
struct WebSocketHandshakeTests {

    private func upgradeRequest(
        target: String = "/api/events?pair=418205",
        method: String = "GET",
        version: String? = "13",
        key: String? = "dGhlIHNhbXBsZSBub25jZQ==",
        connection: String = "Upgrade",
        upgrade: String? = "websocket"
    ) -> HTTPRequest {
        var headers = HTTPHeaders()
        headers["Host"] = "mac.local"
        headers["Connection"] = connection
        if let upgrade { headers["Upgrade"] = upgrade }
        if let version { headers["Sec-WebSocket-Version"] = version }
        if let key { headers["Sec-WebSocket-Key"] = key }
        return HTTPRequest(method: method, target: target, headers: headers)
    }

    @Test("the RFC 6455 §1.3 example key produces the RFC's accept value")
    func rfcExample() {
        // The one interoperability fact in the protocol. If this is wrong, every client fails the
        // handshake and no amount of internal consistency helps.
        #expect(
            WebSocketHandshake.accept(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    @Test("an upgrade request is recognised, and an ordinary request is not")
    func recognition() {
        #expect(WebSocketHandshake.isUpgrade(upgradeRequest()))
        #expect(WebSocketHandshake.isUpgrade(upgradeRequest(connection: "keep-alive, Upgrade")))
        #expect(WebSocketHandshake.isUpgrade(upgradeRequest(upgrade: "WebSocket")))
        #expect(!WebSocketHandshake.isUpgrade(HTTPRequest(method: "GET", target: "/api/sessions")))
        // `Upgrade: websocket` without `Connection: Upgrade` is not an upgrade — it is a header a
        // proxy forgot to strip.
        #expect(!WebSocketHandshake.isUpgrade(upgradeRequest(connection: "keep-alive")))
    }

    @Test("a valid upgrade is a 101 with the accept header and no Content-Length")
    func validUpgrade() throws {
        let response = try WebSocketHandshake.response(for: upgradeRequest())
        #expect(response.status == 101)
        #expect(!response.closeConnection)
        let names = response.headers.map { $0.name.lowercased() }
        #expect(names.contains("sec-websocket-accept"))
        let accept = try #require(response.headers.first { $0.name == "Sec-WebSocket-Accept" })
        #expect(accept.value == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

        let bytes = try #require(String(data: response.serialized(), encoding: .utf8))
        #expect(bytes.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        // A 101 that also declares a length or a second Connection header is a handshake a strict
        // client rejects.
        #expect(!bytes.lowercased().contains("content-length"))
        #expect(bytes.components(separatedBy: "Connection:").count == 2)
        #expect(bytes.hasSuffix("\r\n\r\n"))
    }

    @Test("a non-upgrade request is not treated as a failed handshake")
    func notAnUpgrade() {
        #expect(throws: WebSocketHandshake.Failure.notAnUpgrade) {
            try WebSocketHandshake.response(for: HTTPRequest(method: "GET", target: "/api/health"))
        }
    }

    @Test("a POST cannot upgrade")
    func wrongMethod() {
        #expect(throws: WebSocketHandshake.Failure.unsupportedMethod) {
            try WebSocketHandshake.response(for: upgradeRequest(method: "POST"))
        }
    }

    @Test("a missing key is refused")
    func missingKey() {
        #expect(throws: WebSocketHandshake.Failure.missingKey) {
            try WebSocketHandshake.response(for: upgradeRequest(key: nil))
        }
        #expect(WebSocketHandshake.Failure.missingKey.response.status == 400)
    }

    @Test("a version other than 13 is a 426 that says which version is spoken")
    func wrongVersion() throws {
        #expect(throws: WebSocketHandshake.Failure.unsupportedVersion("8")) {
            try WebSocketHandshake.response(for: upgradeRequest(version: "8"))
        }
        #expect(throws: WebSocketHandshake.Failure.unsupportedVersion(nil)) {
            try WebSocketHandshake.response(for: upgradeRequest(version: nil))
        }
        let response = WebSocketHandshake.Failure.unsupportedVersion("8").response
        #expect(response.status == 426)
        let offered = try #require(response.headers.first { $0.name == "Sec-WebSocket-Version" })
        #expect(offered.value == "13")
    }

    @Test("the handshake does not look at the pairing code")
    func handshakeIgnoresPairing() throws {
        // FR-4 is enforced by the router *before* this, because a wrong code must close without
        // upgrading. A handshake that succeeds and then closes has already said "the path exists".
        let response = try WebSocketHandshake.response(for: upgradeRequest(target: "/api/events"))
        #expect(response.status == 101)
    }
}
