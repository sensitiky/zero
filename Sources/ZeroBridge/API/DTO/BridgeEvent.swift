import Foundation

/// One frame on a WebSocket stream (FR-22).
///
/// An enum rather than a struct with thirteen optional payloads: the contract pairs each `type` with
/// exactly the fields it carries, and a struct cannot say that. Every case carries `sessionId`,
/// because a client watching the list stream has to know which row an event belongs to.
public enum BridgeEvent: Sendable, Equatable {
    case sessionSnapshot(sessionId: String, session: SessionDetailDTO)
    case sessionCreated(sessionId: String, session: SessionSummaryDTO)
    case sessionState(sessionId: String, status: SessionStatus, awaitingUser: Bool, error: String?)
    case sessionSummary(sessionId: String, summary: String)
    case agentOutput(
        sessionId: String,
        entryId: String,
        kind: AgentOutputKind,
        content: String,
        mode: AgentOutputMode
    )
    case toolCall(sessionId: String, entryId: String, call: ToolCallDTO)
    case plan(sessionId: String, entryId: String, items: [PlanItemDTO])
    case notice(sessionId: String, entryId: String, text: String)
    /// How a `userText` entry reaches other clients: a message sent from the phone must appear on
    /// the Mac and on any second phone, and it is not agent output.
    case entryAppended(sessionId: String, entry: EntryDTO)
    case permissionRequested(sessionId: String, request: PermissionRequestDTO)
    case permissionResolved(sessionId: String, requestId: String)
    case usage(sessionId: String, usage: UsageDTO)
    case sessionCompleted(sessionId: String)
    case sessionFailed(sessionId: String, error: String)

    public var type: String {
        switch self {
        case .sessionSnapshot: "session.snapshot"
        case .sessionCreated: "session.created"
        case .sessionState: "session.state"
        case .sessionSummary: "session.summary"
        case .agentOutput: "agent.output"
        case .toolCall: "tool.call"
        case .plan: "plan"
        case .notice: "notice"
        case .entryAppended: "entry.appended"
        case .permissionRequested: "permission.requested"
        case .permissionResolved: "permission.resolved"
        case .usage: "usage"
        case .sessionCompleted: "session.completed"
        case .sessionFailed: "session.failed"
        }
    }

    /// Which session this is about. The hub routes on it, so it is not optional in any case.
    public var sessionId: String {
        switch self {
        case .sessionSnapshot(let id, _),
             .sessionCreated(let id, _),
             .sessionState(let id, _, _, _),
             .sessionSummary(let id, _),
             .agentOutput(let id, _, _, _, _),
             .toolCall(let id, _, _),
             .plan(let id, _, _),
             .notice(let id, _, _),
             .entryAppended(let id, _),
             .permissionRequested(let id, _),
             .permissionResolved(let id, _),
             .usage(let id, _),
             .sessionCompleted(let id),
             .sessionFailed(let id, _):
            id
        }
    }

    /// Whether this event belongs on the list-level stream (FR-21), which only wants what changes a
    /// row: a session appearing, its state, its one-line summary. Streaming every delta to a client
    /// that is showing a list is most of the traffic and none of the information.
    public var isListLevel: Bool {
        switch self {
        case .sessionCreated, .sessionState, .sessionSummary:
            true
        case .sessionSnapshot, .agentOutput, .toolCall, .plan, .notice, .entryAppended,
             .permissionRequested, .permissionResolved, .usage, .sessionCompleted, .sessionFailed:
            false
        }
    }
}

extension BridgeEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, sessionId, session, status, awaitingUser, error, summary
        case entryId, kind, content, mode, call, items, text, entry, request, requestId, usage
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        switch self {
        case .sessionSnapshot(_, let session):
            try container.encode(session, forKey: .session)
        case .sessionCreated(_, let session):
            try container.encode(session, forKey: .session)
        case .sessionState(_, let status, let awaitingUser, let error):
            try container.encode(status, forKey: .status)
            try container.encode(awaitingUser, forKey: .awaitingUser)
            try container.encodeExplicit(error, forKey: .error)
        case .sessionSummary(_, let summary):
            try container.encode(summary, forKey: .summary)
        case .agentOutput(_, let entryId, let kind, let content, let mode):
            try container.encode(entryId, forKey: .entryId)
            try container.encode(kind, forKey: .kind)
            try container.encode(content, forKey: .content)
            try container.encode(mode, forKey: .mode)
        case .toolCall(_, let entryId, let call):
            try container.encode(entryId, forKey: .entryId)
            try container.encode(call, forKey: .call)
        case .plan(_, let entryId, let items):
            try container.encode(entryId, forKey: .entryId)
            try container.encode(items, forKey: .items)
        case .notice(_, let entryId, let text):
            try container.encode(entryId, forKey: .entryId)
            try container.encode(text, forKey: .text)
        case .entryAppended(_, let entry):
            try container.encode(entry, forKey: .entry)
        case .permissionRequested(_, let request):
            try container.encode(request, forKey: .request)
        case .permissionResolved(_, let requestId):
            try container.encode(requestId, forKey: .requestId)
        case .usage(_, let usage):
            try container.encode(usage, forKey: .usage)
        case .sessionCompleted:
            break
        case .sessionFailed(_, let error):
            try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        switch type {
        case "session.snapshot":
            self = .sessionSnapshot(
                sessionId: sessionId,
                session: try container.decode(SessionDetailDTO.self, forKey: .session)
            )
        case "session.created":
            self = .sessionCreated(
                sessionId: sessionId,
                session: try container.decode(SessionSummaryDTO.self, forKey: .session)
            )
        case "session.state":
            self = .sessionState(
                sessionId: sessionId,
                status: try container.decode(SessionStatus.self, forKey: .status),
                awaitingUser: try container.decode(Bool.self, forKey: .awaitingUser),
                error: try container.decodeIfPresent(String.self, forKey: .error)
            )
        case "session.summary":
            self = .sessionSummary(
                sessionId: sessionId,
                summary: try container.decode(String.self, forKey: .summary)
            )
        case "agent.output":
            self = .agentOutput(
                sessionId: sessionId,
                entryId: try container.decode(String.self, forKey: .entryId),
                kind: try container.decode(AgentOutputKind.self, forKey: .kind),
                content: try container.decode(String.self, forKey: .content),
                mode: try container.decode(AgentOutputMode.self, forKey: .mode)
            )
        case "tool.call":
            self = .toolCall(
                sessionId: sessionId,
                entryId: try container.decode(String.self, forKey: .entryId),
                call: try container.decode(ToolCallDTO.self, forKey: .call)
            )
        case "plan":
            self = .plan(
                sessionId: sessionId,
                entryId: try container.decode(String.self, forKey: .entryId),
                items: try container.decode([PlanItemDTO].self, forKey: .items)
            )
        case "notice":
            self = .notice(
                sessionId: sessionId,
                entryId: try container.decode(String.self, forKey: .entryId),
                text: try container.decode(String.self, forKey: .text)
            )
        case "entry.appended":
            self = .entryAppended(
                sessionId: sessionId,
                entry: try container.decode(EntryDTO.self, forKey: .entry)
            )
        case "permission.requested":
            self = .permissionRequested(
                sessionId: sessionId,
                request: try container.decode(PermissionRequestDTO.self, forKey: .request)
            )
        case "permission.resolved":
            self = .permissionResolved(
                sessionId: sessionId,
                requestId: try container.decode(String.self, forKey: .requestId)
            )
        case "usage":
            self = .usage(
                sessionId: sessionId,
                usage: try container.decode(UsageDTO.self, forKey: .usage)
            )
        case "session.completed":
            self = .sessionCompleted(sessionId: sessionId)
        case "session.failed":
            self = .sessionFailed(
                sessionId: sessionId,
                error: try container.decode(String.self, forKey: .error)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown event type"
            )
        }
    }
}
