import Foundation
import Network
import Testing

@testable import ZeroBridge

/// FR-1, FR-2, FR-20 — against a real listener, a real handshake and real frames.
///
/// **Always on port 0.** The system picks an ephemeral port, so this suite never collides with a
/// Zero that is running on 4000 while the tests run.
@Suite("BridgeServer")
struct BridgeServerTests {

    // MARK: - Fixtures

    private struct FakeHandler: BridgeRequestHandling {
        var onRespond: @Sendable (HTTPRequest) -> HTTPResponse = { _ in
            HTTPResponse.json(status: 200, OkBody())
        }
        var onSubscribe: @Sendable (HTTPRequest) -> BridgeSubscription = { _ in
            .accept(topic: .global, initial: [])
        }

        func respond(to request: HTTPRequest) async -> HTTPResponse { onRespond(request) }
        func subscribe(to request: HTTPRequest) async -> BridgeSubscription { onSubscribe(request) }
    }

    private enum TestFailure: Error, Equatable {
        case timedOut
        case endOfStream
        case badPort
        case malformedResponse
    }

    private struct RawResponse {
        var status: Int
        var headers: [String: String]
        var body: String
    }

    /// A client that speaks the wire by hand: no `URLSession`, no `NWProtocolWebSocket`. If the
    /// server's bytes are wrong, nothing here papers over it.
    private actor RawClient {
        private let socket: Socket
        private var buffer = Data()
        private var frames = WebSocketFrameDecoder(expectsMaskedFrames: false)

        init(socket: Socket) { self.socket = socket }

        static func connect(to port: UInt16) async throws -> RawClient {
            guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw TestFailure.badPort }
            let connection = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
            let socket = Socket(
                connection: connection,
                queue: DispatchQueue(label: "tech.incu.zero.bridge.tests")
            )
            try await socket.start()
            return RawClient(socket: socket)
        }

        func write(_ string: String) async throws { try await socket.send(Data(string.utf8)) }
        func write(_ data: Data) async throws { try await socket.send(data) }
        func close() { socket.close() }

        private func fill() async throws {
            guard let chunk = try await socket.receive() else { throw TestFailure.endOfStream }
            buffer.append(chunk)
        }

        func readResponse() async throws -> RawResponse {
            while true {
                if let response = try parseResponse() { return response }
                try await fill()
            }
        }

        private func parseResponse() throws -> RawResponse? {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headData = buffer[buffer.startIndex..<separator.lowerBound]
            guard let head = String(data: headData, encoding: .utf8) else {
                throw TestFailure.malformedResponse
            }
            var lines = head.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { throw TestFailure.malformedResponse }
            let statusLine = lines.removeFirst().split(separator: " ")
            guard statusLine.count >= 2, let status = Int(statusLine[1]) else {
                throw TestFailure.malformedResponse
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[line.startIndex..<colon]).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = separator.upperBound
            guard buffer.count >= buffer.distance(from: buffer.startIndex, to: bodyStart) + length
            else { return nil }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = String(data: buffer[bodyStart..<bodyEnd], encoding: .utf8) ?? ""
            buffer = Data(buffer[bodyEnd...])
            // Whatever is left is frame bytes: the server may pipeline the snapshot behind the 101.
            if !buffer.isEmpty {
                frames.append(buffer)
                buffer = Data()
            }
            return RawResponse(status: status, headers: headers, body: body)
        }

        func readFrame() async throws -> WebSocketFrame {
            while true {
                if let frame = try frames.nextFrame() { return frame }
                guard let chunk = try await socket.receive() else { throw TestFailure.endOfStream }
                frames.append(chunk)
            }
        }

        /// Reads until the peer stops sending, returning what arrived. Used to assert that the
        /// server closed rather than left the connection open.
        func readUntilEnd() async throws -> [WebSocketFrame] {
            var collected: [WebSocketFrame] = []
            while true {
                while let frame = try frames.nextFrame() { collected.append(frame) }
                do {
                    // A peer that closed can surface as end-of-stream *or* as a POSIX error,
                    // depending on how far the FIN got before the socket went. Both mean the same
                    // thing here: there is nothing more to read.
                    guard let chunk = try await socket.receive() else { return collected }
                    frames.append(chunk)
                } catch {
                    return collected
                }
            }
        }
    }

    /// A masked client frame, as RFC 6455 requires of a client.
    private func clientFrame(_ opcode: WebSocketOpcode, _ payload: Data = Data()) -> Data {
        let mask: [UInt8] = [0x21, 0x09, 0xBE, 0x4F]
        var bytes: [UInt8] = [0x80 | opcode.rawValue, 0x80 | UInt8(payload.count)]
        bytes.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() { bytes.append(byte ^ mask[index % 4]) }
        return Data(bytes)
    }

    private func upgradeRequest(_ path: String) -> String {
        """
        GET \(path) HTTP/1.1\r
        Host: 127.0.0.1\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r\n
        """
    }

    /// Nothing in this suite may hang a CI run waiting on a socket that will never speak.
    private func withTimeout<T: Sendable>(
        _ duration: Duration = .seconds(10),
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TestFailure.timedOut
            }
            guard let result = try await group.next() else { throw TestFailure.timedOut }
            group.cancelAll()
            return result
        }
    }

    private func started(
        _ handler: FakeHandler = FakeHandler(),
        hub: EventHub = EventHub(),
        pingInterval: Duration = .seconds(30)
    ) async throws -> (server: BridgeServer, port: UInt16) {
        let server = BridgeServer(handler: handler, hub: hub, pingInterval: pingInterval)
        let port = try await server.start(port: 0)
        return (server, port)
    }

    // MARK: - Binding (FR-2, FR-3)

    @Test("a server binds an ephemeral port and reports it")
    func bindsAndReports() async throws {
        let (server, port) = try await started()
        #expect(port != 0)
        #expect(await server.isListening)
        #expect(await server.port == port)
        await server.stop()
        #expect(await server.isListening == false)
        #expect(await server.port == nil)
    }

    @Test("starting twice does not build a second listener")
    func startIsIdempotent() async throws {
        let (server, port) = try await started()
        let second = try await server.start(port: 0)
        // The thing most likely to go wrong with a toggle, and it does not fail loudly: a second
        // listener leaks a port that nothing can close.
        #expect(second == port)
        #expect(await server.port == port)
        await server.stop()
    }

    @Test("stopping twice is safe, and the same instance starts again afterwards")
    func stopThenStart() async throws {
        let (server, first) = try await started()
        await server.stop()
        await server.stop()
        let second = try await server.start(port: 0)
        #expect(second != 0)
        #expect(await server.isListening)
        _ = first
        // And it still serves.
        let client = try await RawClient.connect(to: second)
        try await client.write("GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        let response = try await withTimeout { try await client.readResponse() }
        #expect(response.status == 200)
        await client.close()
        await server.stop()
    }

    // MARK: - HTTP mode (FR-1)

    @Test("a request is parsed, handed to the handler, and answered")
    func servesHTTP() async throws {
        let handler = FakeHandler(onRespond: { request in
            HTTPResponse.json(
                status: 200,
                HealthDTO(version: request.path, sessionCount: request.headers["x-zero-pair"] == nil ? 0 : 3)
            )
        })
        let (server, port) = try await started(handler)
        let client = try await RawClient.connect(to: port)
        try await client.write(
            "GET /api/health HTTP/1.1\r\nHost: x\r\nX-Zero-Pair: 418205\r\nConnection: close\r\n\r\n"
        )
        let response = try await withTimeout { try await client.readResponse() }
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json; charset=utf-8")
        #expect(response.body == #"{"app":"Zero","sessionCount":3,"version":"\/api\/health"}"#
            .replacingOccurrences(of: "\\/", with: "/"))
        await client.close()
        await server.stop()
    }

    @Test("keep-alive serves two requests on one connection")
    func keepAlive() async throws {
        let (server, port) = try await started()
        let client = try await RawClient.connect(to: port)
        try await client.write("GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try await withTimeout { try await client.readResponse() }.status == 200)
        try await client.write("GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        #expect(try await withTimeout { try await client.readResponse() }.status == 200)
        await client.close()
        await server.stop()
    }

    @Test("a body over the cap is 413 and the connection closes")
    func oversizeBody() async throws {
        let (server, port) = try await started()
        let client = try await RawClient.connect(to: port)
        try await client.write(
            "POST /api/sessions HTTP/1.1\r\nHost: x\r\nContent-Length: \(BridgeLimits.body + 1)\r\n\r\n"
        )
        let response = try await withTimeout { try await client.readResponse() }
        #expect(response.status == 413)
        #expect(response.body.contains("too_large"))
        await client.close()
        await server.stop()
    }

    @Test("a malformed request is 400 and the connection closes")
    func malformedRequest() async throws {
        let (server, port) = try await started()
        let client = try await RawClient.connect(to: port)
        try await client.write("NONSENSE\r\n\r\n")
        let response = try await withTimeout { try await client.readResponse() }
        #expect(response.status == 400)
        #expect(response.body.contains("bad_request"))
        await client.close()
        await server.stop()
    }

    // MARK: - The upgrade (FR-1, FR-4, FR-20)

    @Test("a real handshake, a snapshot first, a live event, and a ping answered")
    func handshakeAndFrames() async throws {
        let hub = EventHub()
        let snapshot = BridgeEvent.sessionSnapshot(
            sessionId: "A",
            session: SessionDetailDTO(
                session: SessionSummaryDTO(
                    id: "A", title: "t", summary: "s", status: .running,
                    projectId: "/p", projectName: "p", provider: "Claude Code",
                    model: "claude-opus-5", branch: "b", workspace: .currentCheckout,
                    permissionMode: .ask, awaitingUser: false
                ),
                entries: [],
                usage: UsageDTO()
            )
        )
        let handler = FakeHandler(onSubscribe: { _ in
            .accept(topic: .session("A"), initial: [snapshot])
        })
        let (server, port) = try await started(handler, hub: hub)
        let client = try await RawClient.connect(to: port)

        try await client.write(upgradeRequest("/api/sessions/A/events?pair=418205"))
        let handshake = try await withTimeout { try await client.readResponse() }
        #expect(handshake.status == 101)
        #expect(handshake.headers["sec-websocket-accept"] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        #expect(handshake.headers["upgrade"] == "websocket")

        // FR-20: the first frame is always the snapshot.
        let first = try await withTimeout { try await client.readFrame() }
        #expect(first.opcode == .text)
        #expect(try BridgeJSON.decode(BridgeEvent.self, from: first.payload) == snapshot)

        // A live event reaches it through the hub.
        let live = BridgeEvent.agentOutput(
            sessionId: "A", entryId: "e1", kind: .assistant, content: "Looking at AuthGuard.ts",
            mode: .replace
        )
        hub.publish(live)
        let second = try await withTimeout { try await client.readFrame() }
        #expect(try BridgeJSON.decode(BridgeEvent.self, from: second.payload) == live)

        // FR-25: the server answers pings.
        try await client.write(clientFrame(.ping, Data("hi".utf8)))
        let pong = try await withTimeout { try await client.readFrame() }
        #expect(pong.opcode == .pong)
        #expect(pong.payload == Data("hi".utf8))

        // The client closing takes its channel with it, and nothing else.
        try await client.write(clientFrame(.close, Data([0x03, 0xE8])))
        let tail = try await withTimeout { try await client.readUntilEnd() }
        #expect(tail.last?.opcode == .close)
        await client.close()

        try await withTimeout {
            while await server.clientCount != 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(await server.clientCount == 0)
        await server.stop()
    }

    @Test("a refused subscription never upgrades (FR-4)")
    func refusedSubscriptionDoesNotUpgrade() async throws {
        let handler = FakeHandler(onSubscribe: { _ in .reject(HTTPResponse.error(.unpaired)) })
        let (server, port) = try await started(handler)
        let client = try await RawClient.connect(to: port)
        try await client.write(upgradeRequest("/api/events"))
        let response = try await withTimeout { try await client.readResponse() }
        // 401 and no `Sec-WebSocket-Accept`: upgrading and then closing would already have said
        // "this path exists".
        #expect(response.status == 401)
        #expect(response.headers["sec-websocket-accept"] == nil)
        #expect(response.body.contains("unpaired"))
        #expect(await server.clientCount == 0)
        await client.close()
        await server.stop()
    }

    @Test("an unknown session closes with 1008 after the handshake")
    func unknownSessionClosesAfterHandshake() async throws {
        let handler = FakeHandler(onSubscribe: { _ in
            .closeAfterUpgrade(.policyViolation, "unknown session")
        })
        let (server, port) = try await started(handler)
        let client = try await RawClient.connect(to: port)
        try await client.write(upgradeRequest("/api/sessions/nope/events?pair=418205"))
        #expect(try await withTimeout { try await client.readResponse() }.status == 101)
        let frames = try await withTimeout { try await client.readUntilEnd() }
        #expect(frames.count == 1)
        #expect(frames.first?.opcode == .close)
        #expect(frames.first?.closeCode == 1008)
        await client.close()
        await server.stop()
    }

    @Test("stopping the bridge closes an open client (FR-2)")
    func stopClosesClients() async throws {
        let (server, port) = try await started()
        let client = try await RawClient.connect(to: port)
        try await client.write(upgradeRequest("/api/events?pair=418205"))
        #expect(try await withTimeout { try await client.readResponse() }.status == 101)
        try await withTimeout {
            while await server.clientCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(await server.clientCount == 1)

        await server.stop()
        let frames = try await withTimeout { try await client.readUntilEnd() }
        #expect(frames.last?.opcode == .close)
        #expect(frames.last?.closeCode == 1001)
        await client.close()
    }

    // MARK: - The router, over a real socket

    /// The one place the real `BridgeRouter` meets the real listener.
    ///
    /// Everything else in this suite uses a fake handler and everything in `BridgeRouterTests` uses
    /// a fake socket, which between them would still pass if the header name the router reads and
    /// the header name a client sends had drifted apart.
    private struct MinimalHost: BridgeHost {
        func health() async -> HealthDTO { HealthDTO(version: "0.1.0", sessionCount: 0) }
        func projects() async -> [ProjectDTO] { [ProjectDTO(id: "/p", name: "p")] }
        func sessions() async -> [SessionSummaryDTO] { [] }
        func session(id: String) async throws -> SessionDetailDTO { throw BridgeError.sessionNotFound }
        func createSession(_ request: CreateSessionRequest) async throws -> SessionDetailDTO {
            throw BridgeError.conflict("no")
        }
        func sendMessage(_ request: SendMessageRequest, in sessionId: String) async throws {}
        func cancel(sessionId: String) async throws {}
        func answerPermission(_ request: AnswerPermissionRequest, in sessionId: String) async throws {}
    }

    @Test("the real router, over a real socket, with and without the code")
    func routerOverASocket() async throws {
        let code = try #require(PairingCode("418205"))
        let server = BridgeServer(handler: BridgeRouter(host: MinimalHost(), pairingCode: code))
        let port = try await server.start(port: 0)

        let unpaired = try await RawClient.connect(to: port)
        try await unpaired.write("GET /api/projects HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        let refused = try await withTimeout { try await unpaired.readResponse() }
        #expect(refused.status == 401)
        #expect(refused.body.contains("unpaired"))
        #expect(!refused.body.contains("418205"))
        await unpaired.close()

        let paired = try await RawClient.connect(to: port)
        try await paired.write(
            "GET /api/projects HTTP/1.1\r\nHost: x\r\nX-Zero-Pair: 418205\r\nConnection: close\r\n\r\n"
        )
        let allowed = try await withTimeout { try await paired.readResponse() }
        #expect(allowed.status == 200)
        #expect(allowed.body == #"[{"id":"/p","name":"p"}]"#)
        await paired.close()

        // And the same code on the query string is what opens a stream (FR-4).
        let streaming = try await RawClient.connect(to: port)
        try await streaming.write(upgradeRequest("/api/events?pair=418205"))
        #expect(try await withTimeout { try await streaming.readResponse() }.status == 101)
        await streaming.close()

        let wrongCode = try await RawClient.connect(to: port)
        try await wrongCode.write(upgradeRequest("/api/events?pair=000000"))
        let rejected = try await withTimeout { try await wrongCode.readResponse() }
        #expect(rejected.status == 401)
        #expect(rejected.headers["sec-websocket-accept"] == nil)
        await wrongCode.close()

        await server.stop()
    }

    @Test("a client that stops draining is dropped, and the server keeps serving")
    func slowClientIsDropped() async throws {
        let hub = EventHub()
        let (server, port) = try await started(hub: hub)
        let client = try await RawClient.connect(to: port)
        try await client.write(upgradeRequest("/api/events?pair=418205"))
        #expect(try await withTimeout { try await client.readResponse() }.status == 101)
        try await withTimeout {
            while await server.clientCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }

        // Nothing on this connection is ever read, so the queue can only grow — until the cap.
        let filler = String(repeating: "x", count: 4096)
        for index in 0..<(BridgeLimits.sendQueue * 8) {
            hub.publish(.sessionSummary(sessionId: "\(index)", summary: filler))
        }
        try await withTimeout(.seconds(20)) {
            while hub.clientCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(hub.clientCount == 0)

        // The listener is unaffected: one bad phone is not the bridge.
        let second = try await RawClient.connect(to: port)
        try await second.write("GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        #expect(try await withTimeout { try await second.readResponse() }.status == 200)
        await second.close()
        await client.close()
        await server.stop()
    }
}
