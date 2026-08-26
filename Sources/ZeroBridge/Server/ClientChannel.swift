import Foundation
import Synchronization

/// One connected WebSocket client, from the hub's point of view.
///
/// Two things make this a `Mutex`-backed `Sendable` class rather than an actor:
///
/// - **Publishing must not await.** The event sink runs on the main actor as part of applying an
///   event to the window's model (FR-24); it cannot suspend. `send` is synchronous, takes a lock
///   held for a few instructions, and returns.
/// - **Order is the payload.** A transcript delivered out of order is a wrong transcript. A
///   synchronous send preserves the publisher's order by construction; hopping through an actor
///   from a non-async caller would need a `Task` per event, and `Task` ordering is not guaranteed.
///
/// The queue is bounded (FR: bounded memory). A phone that stopped draining is closed with `1013`
/// rather than allowed to grow this until the Mac runs out of memory.
public final class ClientChannel: Sendable {

    /// What sits in the queue: a value, not bytes.
    ///
    /// Encoding happens in the writer task, off the main actor (FR-6). Encoding at `send` would put
    /// a JSON encode of a whole transcript entry on the main actor, once per connected client, in
    /// the middle of applying an event to the window.
    public enum Outbound: Sendable {
        case event(BridgeEvent)
        case frame(WebSocketFrame)

        /// The bytes for the wire, or nil if the event will not encode — which is a bug on this
        /// side, and one the client is better off not being disconnected for.
        public func encoded() -> Data? {
            switch self {
            case .frame(let frame):
                return frame.encoded()
            case .event(let event):
                guard let data = try? BridgeJSON.encode(event) else { return nil }
                return WebSocketFrame(opcode: .text, payload: data).encoded()
            }
        }
    }

    public let id: UUID
    public let topic: EventHub.Topic

    private struct State {
        var queued = 0
        var isClosed = false
        var pinger: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<Outbound>.Continuation

    /// What to write to the socket, in order. The connection's writer task encodes each item and
    /// calls `dequeued()` after the write.
    public let outbound: AsyncStream<Outbound>

    public init(topic: EventHub.Topic, id: UUID = UUID()) {
        self.id = id
        self.topic = topic
        let (stream, continuation) = AsyncStream<Outbound>.makeStream(bufferingPolicy: .unbounded)
        // Unbounded here, bounded by `State.queued` below: `.bufferingNewest` would drop a frame
        // silently, and a client that silently lost a frame is a client showing a wrong transcript
        // with no way to know it.
        self.outbound = stream
        self.continuation = continuation
    }

    public var isClosed: Bool { state.withLock(\.isClosed) }

    /// How many frames are written but not yet on the wire. Bounded by `BridgeLimits.sendQueue`.
    public var queueDepth: Int { state.withLock(\.queued) }

    /// Queue one event. `false` means the channel is gone — closed, or just evicted for being too
    /// far behind — and the hub should forget it.
    @discardableResult
    public func send(_ event: BridgeEvent) -> Bool {
        enqueue(.event(event), isControl: false)
    }

    @discardableResult
    public func sendFrame(_ frame: WebSocketFrame) -> Bool {
        enqueue(.frame(frame), isControl: frame.opcode.isControl)
    }

    /// Called by the writer after a frame has reached the socket.
    public func dequeued() {
        state.withLock { if $0.queued > 0 { $0.queued -= 1 } }
    }

    /// Send the close frame and finish the stream. Idempotent.
    public func close(_ code: WebSocketCloseCode = .normal, reason: String = "") {
        let pinger: Task<Void, Never>?
        let wasOpen: Bool
        (wasOpen, pinger) = state.withLock { current in
            guard !current.isClosed else { return (false, nil) }
            current.isClosed = true
            let pinger = current.pinger
            current.pinger = nil
            return (true, pinger)
        }
        guard wasOpen else { return }
        pinger?.cancel()
        continuation.yield(.frame(WebSocketFrame.close(code, reason: reason)))
        continuation.finish()
    }

    /// Keepalive (FR-25). A phone that sleeps produces a clean close rather than a half-open socket
    /// that looks connected and delivers nothing.
    public func startPinging(every interval: Duration = BridgeLimits.pingInterval) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !self.isClosed else { return }
                self.sendFrame(.ping())
            }
        }
        let replaced: Task<Void, Never>? = state.withLock { current in
            guard !current.isClosed else { return task }
            let previous = current.pinger
            current.pinger = task
            return previous
        }
        replaced?.cancel()
    }

    // MARK: - Bounded queue

    private enum Decision { case accepted, dropped, overflow }

    private func enqueue(_ item: Outbound, isControl: Bool) -> Bool {
        let decision: Decision = state.withLock { current in
            if current.isClosed { return .dropped }
            // A control frame is small, and refusing a pong for being behind is how a connection
            // that would have recovered gets torn down instead.
            if !isControl, current.queued >= BridgeLimits.sendQueue {
                current.isClosed = true
                return .overflow
            }
            current.queued += 1
            return .accepted
        }
        switch decision {
        case .accepted:
            continuation.yield(item)
            return true
        case .dropped:
            return false
        case .overflow:
            let pinger: Task<Void, Never>? = state.withLock { current in
                let pinger = current.pinger
                current.pinger = nil
                return pinger
            }
            pinger?.cancel()
            continuation.yield(
                .frame(WebSocketFrame.close(.tryAgainLater, reason: "send queue full"))
            )
            continuation.finish()
            return false
        }
    }
}
