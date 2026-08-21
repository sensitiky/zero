import Foundation

/// What Zero knows how to show. Every provider protocol is decoded into this and nothing else,
/// so no view, store or state machine in the app ever branches on which agent produced it.
public enum AgentEvent: Sendable, Equatable {
    case turnStarted(id: String)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCall(ToolCall)
    case plan([PlanItem])
    case permissionRequested(PermissionRequest)
    case usage(Usage)
    /// A running token estimate while the model thinks.
    ///
    /// Separate from `.usage` on purpose: that case means the turn's settled accounting, and
    /// folding a live estimate into it leaves consumers unable to tell a partial guess from a
    /// total they can bill against.
    case thinkingProgress(estimatedTokens: Int)
    case turnEnded(StopReason)
    case failed(reason: String)

    /// A record that decoded as JSON but matched nothing known. Kept rather than dropped: a
    /// provider adding an event type should surface as a visible gap, not as missing output.
    case unrecognized(raw: Data)
}

public enum StopReason: Sendable, Equatable {
    case endTurn
    case maxTokens
    case cancelled
    case refusal
    case error(String)
}

// MARK: - Tool calls

public struct ToolCall: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case pending
        case running
        case succeeded
        case failed(String)
        case denied
    }

    public var id: String
    public var name: String
    public var input: String?
    public var output: String?
    public var status: Status
    /// Present when the call edits a file, so the UI can render a diff instead of raw text (FR-20).
    public var edit: FileEdit?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: String,
        name: String,
        input: String? = nil,
        output: String? = nil,
        status: Status = .pending,
        edit: FileEdit? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.status = status
        self.edit = edit
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct FileEdit: Sendable, Equatable {
    public var path: String
    public var oldText: String?
    public var newText: String?

    public init(path: String, oldText: String? = nil, newText: String? = nil) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
}

public struct PlanItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case pending, inProgress, completed
    }

    public var id: String
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

// MARK: - Permissions

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    /// The provider's correlation id. The response must carry it back or the agent hangs.
    public var id: String
    public var toolName: String
    /// Human-readable and complete. Truncating this is how a user approves something they did
    /// not read, so the UI is responsible for scrolling it, not for shortening it.
    public var detail: String
    public var options: [PermissionOption]

    public init(id: String, toolName: String, detail: String, options: [PermissionOption]) {
        self.id = id
        self.toolName = toolName
        self.detail = detail
        self.options = options
    }
}

public struct PermissionOption: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case allowOnce, allowAlways, denyOnce, denyAlways
    }

    public var id: String
    public var kind: Kind
    public var label: String

    public init(id: String, kind: Kind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}

/// Where a permission resolution came from.
///
/// This exists to make FR-25 a property of the type system rather than a convention: the only way
/// to resolve a request is to name a human origin. Nothing decoded from a model response or a tool
/// result can construct one, so no amount of injected text in tool output can approve a tool call.
public struct PermissionOrigin: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The user acted on the request in the UI.
        case userAction
        /// A rule the user configured before this request existed.
        case userConfiguredRule(name: String)
    }

    public let source: Source

    public static let userAction = PermissionOrigin(source: .userAction)

    public static func rule(_ name: String) -> PermissionOrigin {
        PermissionOrigin(source: .userConfiguredRule(name: name))
    }

    private init(source: Source) {
        self.source = source
    }
}

// MARK: - Usage

public struct Usage: Sendable, Equatable {
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var contextWindowUsed: Int?
    public var contextWindowTotal: Int?
    public var thinkingTokens: Int?

    /// Cost as reported by the provider, when it reports one.
    ///
    /// Present so a provider's own figure beats our price table (FR-30). Claude Code reports
    /// `total_cost_usd`; a provider that reports nothing leaves this nil and falls back to the table.
    public var costUSD: Double?

    public init(
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        contextWindowUsed: Int? = nil,
        contextWindowTotal: Int? = nil,
        thinkingTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.contextWindowUsed = contextWindowUsed
        self.contextWindowTotal = contextWindowTotal
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
    }
}
