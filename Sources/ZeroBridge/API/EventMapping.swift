import Foundation
import ZeroCore

/// What the bridge has published about a session, so it can publish only what changed.
///
/// A `session.state` per delta would be most of the traffic and none of the information.
public struct PublishedState: Sendable, Equatable {
    public var status: SessionStatus
    public var awaitingUser: Bool
    public var error: String?
    public var summary: String

    public init(status: SessionStatus, awaitingUser: Bool, error: String?, summary: String) {
        self.status = status
        self.awaitingUser = awaitingUser
        self.error = error
        self.summary = summary
    }
}

extension Projection {

    // MARK: - Which entry an event touched (A4)

    /// The entry an event landed on, *after* `Transcript.apply` has run.
    ///
    /// This mirrors `Transcript`'s own identity rules rather than restating its assembly rules:
    /// everything that appends leaves its entry last (every append clears `openAssistantEntryID`, so
    /// the open assistant message is always the last entry while it is open), and a tool call is
    /// found by the provider's call id because `Transcript.upsert` replaces it in place.
    ///
    /// Reading the entry out instead of reconstructing it is what lets the transport layer contain
    /// no copy of the assembly logic (FR-24) — and it is why v0 sends `replace` and never `append`.
    /// The kind is checked rather than assumed: a mismatch returns nil instead of naming the wrong
    /// entry, and there is no force-unwrap anywhere in the path.
    public static func affectedEntry(
        in entries: [Transcript.Entry],
        for event: AgentEvent
    ) -> Transcript.Entry? {
        switch event {
        case .textDelta:
            if case .assistantText = entries.last { return entries.last }
            return nil

        case .thinkingDelta:
            if case .thinking = entries.last { return entries.last }
            return nil

        case .plan:
            if case .plan = entries.last { return entries.last }
            return nil

        case .toolCall(let call):
            return entries.first { entry in
                if case .tool(_, let other) = entry { return other.id == call.id }
                return false
            }

        case .rateLimit(let status, _) where status != "allowed":
            if case .notice = entries.last { return entries.last }
            return nil

        case .sessionReady, .turnStarted, .turnEnded, .failed, .permissionRequested, .usage,
             .thinkingProgress, .rateLimit, .unrecognized:
            return nil
        }
    }

    // MARK: - Event → frame (A5)

    /// One normalized `AgentEvent` as the frame a client gets, or nothing.
    ///
    /// The events that produce nothing are deliberate, not omissions:
    /// - `.thinkingProgress` is a live estimate, not settled accounting — it is not `usage`, and the
    ///   transcript itself drops it.
    /// - `.rateLimit("allowed", …)` is the absence of a problem; only a non-allowed status becomes a
    ///   notice, exactly as in `Transcript.apply`.
    /// - `.unrecognized` is kept in the domain as a visible gap, but there is nothing on the wire to
    ///   render it as, and forwarding a provider's raw bytes to a phone is not a contract.
    /// - `.sessionReady`, `.turnStarted`, `.turnEnded` and `.failed` are *state* transitions, and
    ///   state travels through `stateEvents` on change only. Emitting `session.state` from here too
    ///   would double every transition.
    public static func bridgeEvent(
        for event: AgentEvent,
        sessionId: String,
        entry: Transcript.Entry?,
        usage: Usage
    ) -> BridgeEvent? {
        switch event {
        case .textDelta:
            guard case .assistantText(let id, let text) = entry else { return nil }
            return .agentOutput(
                sessionId: sessionId,
                entryId: id.uuidString,
                kind: .assistant,
                content: text,
                // Always `replace`, carrying the entry's full current text. See CONTRACT.md: an
                // `append` implementation would have to reconstruct `Transcript`'s assembly rules
                // out here, which is the one thing FR-24 exists to prevent.
                mode: .replace
            )

        case .thinkingDelta:
            guard case .thinking(let id, let text) = entry else { return nil }
            return .agentOutput(
                sessionId: sessionId,
                entryId: id.uuidString,
                kind: .thinking,
                content: text,
                mode: .replace
            )

        case .toolCall:
            guard case .tool(let id, let call) = entry else { return nil }
            return .toolCall(sessionId: sessionId, entryId: id.uuidString, call: toolCall(call))

        case .plan:
            guard case .plan(let id, let items) = entry else { return nil }
            return .plan(
                sessionId: sessionId,
                entryId: id.uuidString,
                items: items.map(planItem)
            )

        case .rateLimit(let status, _) where status != "allowed":
            guard case .notice(let id, let text) = entry else { return nil }
            return .notice(sessionId: sessionId, entryId: id.uuidString, text: text)

        case .permissionRequested(let request):
            return .permissionRequested(sessionId: sessionId, request: permissionRequest(request))

        case .usage:
            // The transcript's merged figure, not the event's own: usage arrives more than once per
            // turn and a later report supersedes an earlier one field by field. Sending the raw
            // event would hand the client a partial that erases fields it already had.
            return .usage(sessionId: sessionId, usage: self.usage(usage))

        case .sessionReady, .turnStarted, .turnEnded, .failed, .thinkingProgress, .rateLimit,
             .unrecognized:
            return nil
        }
    }

    /// Convenience over `affectedEntry` + `bridgeEvent`, for a caller holding the post-apply
    /// transcript — which is what the adapter has.
    public static func bridgeEvent(
        for event: AgentEvent,
        sessionId: String,
        transcript: Transcript
    ) -> BridgeEvent? {
        bridgeEvent(
            for: event,
            sessionId: sessionId,
            entry: affectedEntry(in: transcript.entries, for: event),
            usage: transcript.usage
        )
    }

    // MARK: - State transitions (E3)

    /// The frames a change of state produces, and nothing when nothing changed.
    ///
    /// `session.completed` and `session.failed` accompany the `session.state` that carries them
    /// rather than replacing it: the contract has all three, and a client that only listens for the
    /// terminal ones still gets the transition.
    public static func stateEvents(
        sessionId: String,
        from previous: PublishedState,
        to current: PublishedState
    ) -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        if current.status != previous.status
            || current.awaitingUser != previous.awaitingUser
            || current.error != previous.error {
            events.append(
                .sessionState(
                    sessionId: sessionId,
                    status: current.status,
                    awaitingUser: current.awaitingUser,
                    error: current.error
                )
            )
        }
        if current.status != previous.status {
            switch current.status {
            case .completed:
                events.append(.sessionCompleted(sessionId: sessionId))
            case .failed:
                events.append(
                    .sessionFailed(sessionId: sessionId, error: current.error ?? "unknown")
                )
            case .running, .waiting, .cancelled:
                break
            }
        }
        if current.summary != previous.summary {
            events.append(.sessionSummary(sessionId: sessionId, summary: current.summary))
        }
        return events
    }
}
