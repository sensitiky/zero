import Foundation
import Testing

@testable import ZeroBridge

/// FR-21, FR-25, FR-26 and bounded memory, without a socket in sight.
@Suite("EventHub")
struct EventHubTests {

    private func summary(_ id: String, status: SessionStatus = .running) -> SessionSummaryDTO {
        SessionSummaryDTO(
            id: id,
            title: "Fix authentication bug",
            summary: "Looking at the JWT validation flow",
            status: status,
            projectId: "/Users/dev/millon-core",
            projectName: "millon-core",
            provider: "Claude Code",
            model: "claude-opus-5",
            branch: "zero/fix-authentication-bug",
            workspace: .currentCheckout,
            permissionMode: .ask,
            awaitingUser: false
        )
    }

    private func output(_ sessionId: String, _ text: String) -> BridgeEvent {
        .agentOutput(
            sessionId: sessionId,
            entryId: "entry-1",
            kind: .assistant,
            content: text,
            mode: .replace
        )
    }

    /// Everything queued on a channel so far, decoded back from its frames.
    private func drain(_ channel: ClientChannel, expecting count: Int) async throws -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        var iterator = channel.outbound.makeAsyncIterator()
        while events.count < count, let item = await iterator.next() {
            let data = item.encoded() ?? Data()
            var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
            decoder.append(data)
            while let frame = try decoder.nextFrame() {
                guard frame.opcode == .text else { continue }
                events.append(try BridgeJSON.decode(BridgeEvent.self, from: frame.payload))
            }
        }
        return events
    }

    // MARK: - Routing

    @Test("a session stream gets everything about its session and nothing about another")
    func sessionTopicRouting() async throws {
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        hub.add(channel)

        hub.publish(output("A", "for A"))
        hub.publish(output("B", "for B"))
        hub.publish(.usage(sessionId: "A", usage: UsageDTO(model: "claude-opus-5")))

        let events = try await drain(channel, expecting: 2)
        #expect(events.count == 2)
        #expect(events.first == output("A", "for A"))
        if case .usage(let sessionId, _) = events.last {
            #expect(sessionId == "A")
        } else {
            Issue.record("second event was not the usage frame")
        }
    }

    @Test("the list stream gets only what changes a row (FR-21)")
    func globalTopicRouting() async throws {
        let hub = EventHub()
        let channel = ClientChannel(topic: .global)
        hub.add(channel)

        // Streaming every delta to a client showing a list is most of the traffic and none of the
        // information.
        hub.publish(output("A", "a delta"))
        hub.publish(.toolCall(sessionId: "A", entryId: "e", call: ToolCallDTO(id: "t", name: "Read", status: .running)))
        hub.publish(.sessionCreated(sessionId: "A", session: summary("A")))
        hub.publish(.sessionState(sessionId: "A", status: .waiting, awaitingUser: true, error: nil))
        hub.publish(.sessionSummary(sessionId: "A", summary: "Reading AuthGuard.ts"))

        let events = try await drain(channel, expecting: 3)
        #expect(events.map(\.type) == ["session.created", "session.state", "session.summary"])
    }

    @Test("two clients on one session both get it, and neither knows about the other (FR-26)")
    func fanOut() async throws {
        let hub = EventHub()
        let first = ClientChannel(topic: .session("A"))
        let second = ClientChannel(topic: .session("A"))
        let list = ClientChannel(topic: .global)
        hub.add(first)
        hub.add(second)
        hub.add(list)
        #expect(hub.clientCount == 3)

        hub.publish(output("A", "hello"))
        #expect(try await drain(first, expecting: 1) == [output("A", "hello")])
        #expect(try await drain(second, expecting: 1) == [output("A", "hello")])

        // One going away affects neither the session nor the others.
        hub.remove(first.id)
        first.close()
        #expect(hub.clientCount == 2)
        hub.publish(output("A", "still here"))
        #expect(try await drain(second, expecting: 1) == [output("A", "still here")])
    }

    // MARK: - FR-20: the snapshot is first

    @Test("the initial events are written before the channel can receive anything else")
    func snapshotIsFirst() async throws {
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        let snapshot = BridgeEvent.sessionSnapshot(
            sessionId: "A",
            session: SessionDetailDTO(session: summary("A"), entries: [], usage: UsageDTO())
        )
        hub.add(channel, initial: [snapshot])
        hub.publish(output("A", "arrived after"))

        let events = try await drain(channel, expecting: 2)
        #expect(events.first?.type == "session.snapshot")
        #expect(events.last == output("A", "arrived after"))
    }

    // MARK: - Bounded memory

    @Test("a client that never drains is evicted with 1013 rather than allowed to grow")
    func slowClientEviction() async throws {
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        hub.add(channel)

        for index in 0...(BridgeLimits.sendQueue + 4) {
            hub.publish(output("A", "delta \(index)"))
        }

        #expect(channel.isClosed)
        // The hub forgets it in the same pass that evicted it: publishing never awaits a slow
        // client, and never keeps one either.
        #expect(hub.clientCount == 0)
        #expect(channel.queueDepth <= BridgeLimits.sendQueue)

        var frames: [WebSocketFrame] = []
        for await item in channel.outbound {
            let data = item.encoded() ?? Data()
            var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
            decoder.append(data)
            while let frame = try decoder.nextFrame() { frames.append(frame) }
        }
        #expect(frames.count == BridgeLimits.sendQueue + 1)
        #expect(frames.last?.opcode == .close)
        #expect(frames.last?.closeCode == 1013)
    }

    @Test("a drained client is never evicted")
    func drainingClientSurvives() async throws {
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        hub.add(channel)

        let reader = Task {
            var seen = 0
            for await _ in channel.outbound {
                channel.dequeued()
                seen += 1
                if seen == BridgeLimits.sendQueue * 3 { return seen }
            }
            return seen
        }
        // Waiting for the queue to drain after each publish rather than trusting the scheduler:
        // a reader that simply loses a race would fail this test for a reason that has nothing to
        // do with eviction, and a flaky test asserts nothing.
        for index in 0..<(BridgeLimits.sendQueue * 3) {
            hub.publish(output("A", "delta \(index)"))
            var spins = 0
            while channel.queueDepth > 0, spins < 10_000 {
                await Task.yield()
                spins += 1
            }
        }
        #expect(await reader.value == BridgeLimits.sendQueue * 3)
        #expect(!channel.isClosed)
        #expect(hub.clientCount == 1)
    }

    // MARK: - Lifecycle

    @Test("closeAll closes every client and empties the hub (FR-2)")
    func closeAll() async throws {
        let hub = EventHub()
        let first = ClientChannel(topic: .session("A"))
        let second = ClientChannel(topic: .global)
        hub.add(first)
        hub.add(second)

        hub.closeAll(.goingAway, reason: "bridge stopped")
        #expect(hub.clientCount == 0)
        #expect(first.isClosed)
        #expect(second.isClosed)

        for channel in [first, second] {
            var codes: [UInt16] = []
            for await item in channel.outbound {
                let data = item.encoded() ?? Data()
                var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
                decoder.append(data)
                while let frame = try decoder.nextFrame() {
                    if let code = frame.closeCode { codes.append(code) }
                }
            }
            #expect(codes == [1001])
        }
    }

    @Test("a closed channel refuses further sends and is dropped on the next publish")
    func closedChannelIsDropped() {
        let hub = EventHub()
        let channel = ClientChannel(topic: .session("A"))
        hub.add(channel)
        channel.close(.normal)

        hub.publish(output("A", "after close"))
        #expect(hub.clientCount == 0)
        #expect(!channel.send(output("A", "again")))
    }

    @Test("closing twice is not two close frames")
    func closeIsIdempotent() async throws {
        let channel = ClientChannel(topic: .global)
        channel.close(.normal)
        channel.close(.protocolError)
        var frames = 0
        for await _ in channel.outbound { frames += 1 }
        #expect(frames == 1)
    }

    // MARK: - FR-25

    @Test("the channel pings on its own interval, and stops when it closes")
    func pinging() async throws {
        let channel = ClientChannel(topic: .global)
        channel.startPinging(every: .milliseconds(10))

        var iterator = channel.outbound.makeAsyncIterator()
        let first = try #require(await iterator.next()?.encoded())
        var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
        decoder.append(first)
        #expect(try decoder.nextFrame()?.opcode == .ping)

        channel.close(.normal)
        // What is left is the close frame, and then the stream ends — no ping after the close.
        var opcodes: [WebSocketOpcode] = []
        while let item = await iterator.next() {
            var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
            decoder.append(item.encoded() ?? Data())
            while let frame = try decoder.nextFrame() { opcodes.append(frame.opcode) }
        }
        #expect(opcodes.last == .close)
    }
}
