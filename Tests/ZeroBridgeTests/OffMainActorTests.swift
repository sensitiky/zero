import Foundation
import Network
import Synchronization
import Testing

@testable import ZeroBridge

/// FR-6: accept, HTTP parse, WebSocket framing and JSON encoding happen **off the main actor**.
///
/// Zero's window is the main actor. A server that parses a request or encodes a transcript there
/// makes every connected phone a source of hitches in the desktop UI, and this is the inherited NFR
/// of `001-agent-chat-core` — no I/O and no parsing on the main actor.
@Suite("OffMainActor")
struct OffMainActorTests {

    /// A reference type, for the same reason `ThreadRecorder` in `SessionRuntimeTests` is one: a
    /// struct spy records into whatever copy the server happens to hold, and the test observes an
    /// empty array.
    private final class ThreadRecorder: Sendable {
        private let samples = Mutex<[String: Bool]>([:])

        func record(_ label: String) {
            samples.withLock { $0[label] = Thread.isMainThread }
        }

        func wasMainThread(_ label: String) -> Bool? { samples.withLock { $0[label] } }
        var count: Int { samples.withLock(\.count) }
    }

    private struct RecordingHandler: BridgeRequestHandling {
        let recorder: ThreadRecorder

        func respond(to request: HTTPRequest) async -> HTTPResponse {
            // Reached only after the request line, the headers and the body have been parsed, on
            // the same task that parsed them.
            recorder.record("respond")
            return HTTPResponse.json(status: 200, OkBody())
        }

        func subscribe(to request: HTTPRequest) async -> BridgeSubscription {
            recorder.record("subscribe")
            return .accept(topic: .global, initial: [])
        }
    }

    /// Synchronous, because `Thread.isMainThread` is unavailable directly from an async context.
    private func isMainThread() -> Bool { Thread.isMainThread }

    /// Blocks the calling thread. Synchronous on purpose: `Thread.sleep` is unavailable from an
    /// async context, and blocking is precisely what this test needs the main actor to do.
    private func block(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func connect(to port: UInt16) async throws -> Socket {
        let endpoint = try #require(NWEndpoint.Port(rawValue: port))
        let socket = Socket(
            connection: NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp),
            queue: DispatchQueue(label: "tech.incu.zero.bridge.tests.offmain")
        )
        try await socket.start()
        return socket
    }

    @MainActor
    @Test("HTTP parsing and the handler run off the main actor")
    func httpIsOffMain() async throws {
        #expect(isMainThread())
        let recorder = ThreadRecorder()
        let server = BridgeServer(handler: RecordingHandler(recorder: recorder))
        let port = try await server.start(port: 0)

        let socket = try await connect(to: port)
        try await socket.send(
            Data("GET /api/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8)
        )
        _ = try await socket.receive()
        socket.close()

        #expect(recorder.wasMainThread("respond") == false)
        await server.stop()
    }

    @MainActor
    @Test("the upgrade decision runs off the main actor")
    func upgradeIsOffMain() async throws {
        let recorder = ThreadRecorder()
        let server = BridgeServer(handler: RecordingHandler(recorder: recorder))
        let port = try await server.start(port: 0)

        let socket = try await connect(to: port)
        try await socket.send(Data("""
            GET /api/events?pair=418205 HTTP/1.1\r
            Host: x\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
            Sec-WebSocket-Version: 13\r
            \r\n
            """.utf8))
        _ = try await socket.receive()
        socket.close()

        #expect(recorder.wasMainThread("subscribe") == false)
        await server.stop()
    }

    @MainActor
    @Test("publishing from the main actor queues a value, and encodes nowhere near it")
    func publishingDoesNotEncodeOnThePublisher() async throws {
        // The event sink runs on the main actor as part of applying an event to the window's model
        // (FR-24). If `send` encoded, a JSON encode of a whole transcript entry would run there,
        // once per connected client, in the middle of a UI update.
        #expect(isMainThread())
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        hub.add(channel)
        hub.publish(
            .agentOutput(
                sessionId: "A", entryId: "e1", kind: .assistant,
                content: String(repeating: "text ", count: 10_000), mode: .replace
            )
        )

        var iterator = channel.outbound.makeAsyncIterator()
        let queued = try #require(await iterator.next())
        guard case .event = queued else {
            Issue.record("the queue held bytes, so something encoded on the publisher's thread")
            return
        }

        // And the encode itself, done where the writer does it, is not on the main thread.
        let recorder = ThreadRecorder()
        let writer = Task.detached {
            recorder.record("encode")
            return queued.encoded()
        }
        #expect(await writer.value != nil)
        #expect(recorder.wasMainThread("encode") == false)
    }

    @MainActor
    @Test("a whole exchange completes while the main actor is blocked")
    func exchangeRunsWithTheMainActorBlocked() async throws {
        // The strongest form of the claim: if any part of accept, parse, handshake, framing or
        // encoding needed the main actor, none of this could finish while the main thread is
        // sitting in a `Thread.sleep`. The exchange takes milliseconds; the block is half a second.
        let hub = EventHub()
        let server = BridgeServer(
            handler: RecordingHandler(recorder: ThreadRecorder()),
            hub: hub
        )
        let port = try await server.start(port: 0)
        let finished = Mutex(false)

        let exchange = Task.detached {
            let socket = Socket(
                connection: NWConnection(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: port) ?? .any,
                    using: .tcp
                ),
                queue: DispatchQueue(label: "tech.incu.zero.bridge.tests.blocked")
            )
            try await socket.start()
            try await socket.send(Data("""
                GET /api/events?pair=418205 HTTP/1.1\r
                Host: x\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
                Sec-WebSocket-Version: 13\r
                \r\n
                """.utf8))

            var buffer = Data()
            while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard let chunk = try await socket.receive() else { break }
                buffer.append(chunk)
            }
            // The handshake is done; now a live event has to be encoded and framed.
            hub.publish(.sessionSummary(sessionId: "A", summary: "Reading AuthGuard.ts"))
            var frames = WebSocketFrameDecoder(expectsMaskedFrames: false)
            var received: WebSocketFrame?
            while received == nil {
                guard let chunk = try await socket.receive() else { break }
                frames.append(chunk)
                received = try frames.nextFrame()
            }
            socket.close()
            finished.withLock { $0 = received?.opcode == .text }
        }

        block(for: 0.5)
        #expect(finished.withLock { $0 }, "the exchange needed the main actor to make progress")

        _ = try await exchange.value
        await server.stop()
    }
}
