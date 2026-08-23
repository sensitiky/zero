import Foundation

/// The rendered conversation, assembled from normalized events.
///
/// Lives here rather than in the view layer because the assembly rules are domain logic and they
/// have already been wrong once: streamed text used to merge into whatever assistant entry was last,
/// so each turn's reply was appended to the previous one and the history read as overwritten. That
/// bug was invisible to the test suite while this logic sat inside an observable view model.
public struct Transcript: Sendable, Equatable {
    /// One rendered unit.
    ///
    /// A list of typed entries rather than a string: a tool call, a diff and a plan are different
    /// things to look at, and flattening them into characters is what embedding a terminal does.
    public enum Entry: Identifiable, Sendable, Equatable {
        case userText(id: UUID, text: String)
        case assistantText(id: UUID, text: String)
        case thinking(id: UUID, text: String)
        case tool(id: UUID, call: ToolCall)
        case plan(id: UUID, items: [PlanItem])
        case notice(id: UUID, text: String)

        public var id: UUID {
            switch self {
            case .userText(let id, _), .assistantText(let id, _), .thinking(let id, _),
                 .tool(let id, _), .plan(let id, _), .notice(let id, _):
                return id
            }
        }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var usage = Usage()
    public private(set) var pendingPermission: PermissionRequest?
    /// The latest assistant text, condensed for a one-line summary.
    public private(set) var summary = ""

    /// The assistant message currently being written to.
    ///
    /// Anything that ends a message clears it: a turn boundary, a message from the user, a tool
    /// call, a plan, a thinking block. Without it, "last entry is assistant text" was used as a
    /// stand-in for "we are still in the same message", which is only true within one turn.
    private var openAssistantEntryID: UUID?

    public init() {}

    public mutating func appendUserMessage(_ text: String) {
        entries.append(.userText(id: UUID(), text: text))
        openAssistantEntryID = nil
    }

    /// Appends a plain notice — same shape the rate-limit path already produces, for anything else
    /// that is a fact about the session rather than agent output.
    public mutating func appendNotice(_ text: String) {
        entries.append(.notice(id: UUID(), text: text))
        openAssistantEntryID = nil
    }

    /// Applies one event. Returns the session state it implies, or nil if the event does not change it.
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> SessionState? {
        switch event {
        case .textDelta(let text):
            appendAssistantText(text)
            return nil

        case .thinkingDelta(let text):
            entries.append(.thinking(id: UUID(), text: text))
            openAssistantEntryID = nil
            return nil

        case .toolCall(let call):
            upsert(call)
            openAssistantEntryID = nil
            return nil

        case .plan(let items):
            entries.append(.plan(id: UUID(), items: items))
            openAssistantEntryID = nil
            return nil

        case .permissionRequested(let request):
            pendingPermission = request
            return .waitingPermission

        case .usage(let reported):
            merge(reported)
            return nil

        case .rateLimit(let status, _) where status != "allowed":
            entries.append(.notice(id: UUID(), text: "Rate limited: \(status)"))
            return nil

        case .sessionReady, .turnStarted:
            return .running

        case .turnEnded:
            openAssistantEntryID = nil
            return .idle

        case .failed(let reason):
            openAssistantEntryID = nil
            return .error(reason)

        case .thinkingProgress, .rateLimit, .unrecognized:
            return nil
        }
    }

    public mutating func resolvePermission() {
        pendingPermission = nil
    }

    /// One line, no newlines, bounded. The sidebar has one line of room, and a summary that wraps to
    /// four turns the list into a wall.
    public static func condensed(_ text: String, limit: Int = 90) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: - Assembly

    private mutating func appendAssistantText(_ text: String) {
        if let openAssistantEntryID,
           let position = entries.firstIndex(where: { $0.id == openAssistantEntryID }),
           case .assistantText(let id, let existing) = entries[position] {
            entries[position] = .assistantText(id: id, text: existing + text)
            summary = Self.condensed(existing + text)
        } else {
            let id = UUID()
            entries.append(.assistantText(id: id, text: text))
            openAssistantEntryID = id
            summary = Self.condensed(text)
        }
    }

    /// Replaces a tool call in place when its status changes, so one call stays one row.
    private mutating func upsert(_ call: ToolCall) {
        let existing = entries.firstIndex { entry in
            if case .tool(_, let other) = entry { return other.id == call.id }
            return false
        }
        if let existing, case .tool(let id, _) = entries[existing] {
            entries[existing] = .tool(id: id, call: call)
        } else {
            entries.append(.tool(id: UUID(), call: call))
        }
    }

    /// Usage arrives more than once per turn; a later report supersedes an earlier one field by
    /// field, and a cost the provider reported always wins over anything we would estimate.
    private mutating func merge(_ reported: Usage) {
        usage.model = reported.model ?? usage.model
        usage.inputTokens = reported.inputTokens ?? usage.inputTokens
        usage.outputTokens = reported.outputTokens ?? usage.outputTokens
        usage.cacheReadTokens = reported.cacheReadTokens ?? usage.cacheReadTokens
        usage.cacheWriteTokens = reported.cacheWriteTokens ?? usage.cacheWriteTokens
        usage.thinkingTokens = reported.thinkingTokens ?? usage.thinkingTokens
        usage.contextWindowUsed = reported.contextWindowUsed ?? usage.contextWindowUsed
        usage.contextWindowTotal = reported.contextWindowTotal ?? usage.contextWindowTotal
        usage.costUSD = reported.costUSD ?? usage.costUSD
    }
}
