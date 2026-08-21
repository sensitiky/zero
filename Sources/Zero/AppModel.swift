import Foundation
import Observation
import SwiftUI
import ZeroCore

/// What the UI observes.
///
/// Deliberately thin: it owns no protocol knowledge and no subprocess. Sessions live in
/// `SessionRuntime` actors off the main actor, and this type holds only the `Sendable` snapshots the
/// views render — the NFR forbidding I/O and parsing on the main actor is only meetable if the
/// observable layer never touches either.
@MainActor
@Observable
final class AppModel {
    /// A session as the UI sees it. No model objects, no actors, nothing that must be awaited.
    struct SessionSnapshot: Identifiable, Sendable {
        let id: UUID
        var title: String
        var provider: String
        var model: String
        var branch: String
        var state: SessionState
        var events: [TranscriptEntry] = []
        var usage: Usage = Usage()
        /// Set while the agent is blocked on the user.
        var pendingPermission: PermissionRequest?
    }

    /// One rendered unit of the transcript.
    ///
    /// The transcript is a list of these rather than a string, because a tool call, a diff and a
    /// plan are different things to look at — flattening them into text is what embedding a terminal
    /// does, and avoiding that is the whole point of the product.
    enum TranscriptEntry: Identifiable, Sendable {
        case assistantText(id: UUID, text: String)
        case thinking(id: UUID, text: String)
        case tool(id: UUID, call: ToolCall)
        case plan(id: UUID, items: [PlanItem])
        case notice(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .assistantText(let id, _), .thinking(let id, _), .tool(let id, _),
                 .plan(let id, _), .notice(let id, _):
                return id
            }
        }
    }

    var sessions: [SessionSnapshot] = []
    var selectedSessionID: UUID?
    var inspectorVisible = true
    var composerText = ""

    var selectedSession: SessionSnapshot? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    /// Sessions waiting on the user, for the sidebar's badge.
    var sessionsAwaitingUser: [SessionSnapshot] {
        sessions.filter { $0.pendingPermission != nil }
    }

    // MARK: - Mutation

    func apply(_ event: AgentEvent, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch event {
        case .textDelta(let text):
            appendText(text, at: index)
        case .thinkingDelta(let text):
            sessions[index].events.append(.thinking(id: UUID(), text: text))
        case .toolCall(let call):
            upsertTool(call, at: index)
        case .plan(let items):
            sessions[index].events.append(.plan(id: UUID(), items: items))
        case .permissionRequested(let request):
            sessions[index].pendingPermission = request
            sessions[index].state = .waitingPermission
        case .usage(let usage):
            merge(usage, at: index)
        case .thinkingProgress:
            break
        case .sessionReady, .turnStarted:
            sessions[index].state = .running
        case .rateLimit(let status, _) where status != "allowed":
            sessions[index].events.append(.notice(id: UUID(), text: "Rate limited: \(status)"))
        case .rateLimit:
            break
        case .turnEnded:
            sessions[index].state = .idle
        case .failed(let reason):
            sessions[index].state = .error(reason)
        case .unrecognized:
            break
        }
    }

    func resolvePermission(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].pendingPermission = nil
        sessions[index].state = .running
    }

    /// Appends to the trailing text entry so streamed deltas read as one paragraph rather than one
    /// bubble per token.
    private func appendText(_ text: String, at index: Int) {
        if case .assistantText(let id, let existing) = sessions[index].events.last {
            sessions[index].events[sessions[index].events.count - 1] =
                .assistantText(id: id, text: existing + text)
        } else {
            sessions[index].events.append(.assistantText(id: UUID(), text: text))
        }
    }

    /// Replaces a tool call in place when its status changes, so one call stays one row.
    private func upsertTool(_ call: ToolCall, at index: Int) {
        let existing = sessions[index].events.firstIndex { entry in
            if case .tool(_, let other) = entry { return other.id == call.id }
            return false
        }
        if let existing, case .tool(let id, _) = sessions[index].events[existing] {
            sessions[index].events[existing] = .tool(id: id, call: call)
        } else {
            sessions[index].events.append(.tool(id: UUID(), call: call))
        }
    }

    /// Usage arrives more than once per turn; a later report supersedes an earlier one field by
    /// field, and cost reported by the provider always wins over anything we would estimate.
    private func merge(_ usage: Usage, at index: Int) {
        var current = sessions[index].usage
        current.model = usage.model ?? current.model
        current.inputTokens = usage.inputTokens ?? current.inputTokens
        current.outputTokens = usage.outputTokens ?? current.outputTokens
        current.cacheReadTokens = usage.cacheReadTokens ?? current.cacheReadTokens
        current.cacheWriteTokens = usage.cacheWriteTokens ?? current.cacheWriteTokens
        current.thinkingTokens = usage.thinkingTokens ?? current.thinkingTokens
        current.contextWindowUsed = usage.contextWindowUsed ?? current.contextWindowUsed
        current.contextWindowTotal = usage.contextWindowTotal ?? current.contextWindowTotal
        current.costUSD = usage.costUSD ?? current.costUSD
        sessions[index].usage = current
    }
}
