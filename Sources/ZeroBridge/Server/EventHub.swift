import Foundation
import Synchronization

/// Fan-out: one published event to every client that asked for it (FR-21, FR-26).
///
/// Several clients may watch one session at once, and a client going away affects neither the
/// session nor the other clients — the hub is the only thing that knows any of them exist.
///
/// Synchronous, for the reason spelled out on `ClientChannel`: the publisher is the main actor
/// applying an event to the window's model, it cannot suspend, and the order it publishes in is the
/// order the transcript reads in.
public final class EventHub: Sendable {

    /// What a client subscribed to.
    public enum Topic: Sendable, Hashable {
        /// `/api/events` — list-level changes only, so a client showing a list is not sent every
        /// delta of every session.
        case global
        /// `/api/sessions/:id/events` — everything about one session.
        case session(String)

        func wants(_ event: BridgeEvent) -> Bool {
            switch self {
            case .global: event.isListLevel
            case .session(let id): event.sessionId == id
            }
        }
    }

    private let channels = Mutex<[UUID: ClientChannel]>([:])

    public init() {}

    public var clientCount: Int { channels.withLock(\.count) }

    /// Register a channel, after queueing whatever it must see first.
    ///
    /// `initial` is written **before** the channel can receive anything else, which is what makes
    /// `session.snapshot` the first frame (FR-20). Registering first and sending the snapshot after
    /// would put any event that landed in between ahead of it, and a client that applied an event
    /// and then a snapshot has a transcript that is quietly one step stale.
    public func add(_ channel: ClientChannel, initial: [BridgeEvent] = []) {
        channels.withLock { channels in
            for event in initial where !channel.send(event) { return }
            guard !channel.isClosed else { return }
            channels[channel.id] = channel
        }
    }

    public func remove(_ id: UUID) {
        channels.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Publish to every interested client. Never awaits one: a slow client is evicted, not waited
    /// for.
    public func publish(_ event: BridgeEvent) {
        channels.withLock { channels in
            var evicted: [UUID] = []
            for (id, channel) in channels where channel.topic.wants(event) {
                if !channel.send(event) { evicted.append(id) }
            }
            for id in evicted { channels.removeValue(forKey: id) }
        }
    }

    /// Publish several events as one ordered batch, so nothing can interleave between them.
    public func publish(_ events: [BridgeEvent]) {
        for event in events { publish(event) }
    }

    /// Stopping the bridge closes every open connection (FR-2).
    public func closeAll(_ code: WebSocketCloseCode = .goingAway, reason: String = "") {
        channels.withLock { channels in
            for channel in channels.values { channel.close(code, reason: reason) }
            channels.removeAll()
        }
    }
}
