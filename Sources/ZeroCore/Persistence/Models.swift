import Foundation
import SwiftData

// MARK: - Repository

/// A local git repository that can host worktrees.
@Model
public final class Repository {
    @Attribute(.unique) public var id: UUID
    public var path: String
    public var name: String
    public var defaultBranch: String
    public var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Session.repository)
    public var sessions: [Session] = []

    public init(id: UUID = UUID(), path: String, name: String, defaultBranch: String) {
        self.id = id
        self.path = path
        self.name = name
        self.defaultBranch = defaultBranch
        self.createdAt = Date()
    }
}

// MARK: - Session

/// A persistent conversation with an agent in a dedicated worktree.
@Model
public final class Session {
    @Attribute(.unique) public var id: UUID
    public var repository: Repository?
    public var provider: String
    public var model: String
    public var worktreePath: String
    public var branch: String
    public var state: String // idle, running, waitingPermission, error, finished
    public var providerSessionId: String? // for resuming
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var errorMessage: String?

    /// Monotonic counters for append ordering.
    ///
    /// Held on the session rather than derived from the collections: deriving `max + 1` means
    /// faulting every existing row on every append, which is O(n) per append and O(n²) per
    /// session. That cost is what an earlier revision of this file measured and mistook for
    /// SwiftData being unsuitable — see MEASUREMENTS.md.
    public var nextMessageSequence: Int = 0
    public var nextUsageSequence: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    public var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \UsageRecord.session)
    public var usageRecords: [UsageRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PermissionRequestRecord.session)
    public var permissionRequests: [PermissionRequestRecord] = []

    /// The transcript in order.
    ///
    /// SwiftData relationships are unordered, so reading `messages` directly renders a conversation
    /// in whatever order the store happens to return. That used to look correct only because a
    /// `save()` on every append coincidentally preserved insertion order — a guarantee that
    /// vanished the moment appends were batched. Always read a transcript through here.
    public var orderedMessages: [Message] {
        messages.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    /// Usage in order, for the same reason.
    public var orderedUsageRecords: [UsageRecord] {
        usageRecords.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    public init(
        id: UUID = UUID(),
        repository: Repository? = nil,
        provider: String,
        model: String,
        worktreePath: String,
        branch: String,
        state: String = "idle",
        providerSessionId: String? = nil
    ) {
        self.id = id
        self.repository = repository
        self.provider = provider
        self.model = model
        self.worktreePath = worktreePath
        self.branch = branch
        self.state = state
        self.providerSessionId = providerSessionId
        self.createdAt = Date()
    }
}

// MARK: - Message

/// A single message in the chat transcript.
/// Message ordering uses sequenceNumber for stability when messages arrive out of order.
@Model
public final class Message {
    @Attribute(.unique) public var id: UUID
    public var session: Session?
    public var role: String // user, assistant, system
    public var content: String
    public var sequenceNumber: Int // stable ordering, not dependent on insertion or timestamps
    public var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ToolCallRecord.message)
    public var toolCalls: [ToolCallRecord] = []

    public init(
        id: UUID = UUID(),
        session: Session? = nil,
        role: String,
        content: String,
        sequenceNumber: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.role = role
        self.content = content
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
    }
}

// MARK: - ToolCallRecord

/// A tool invocation during a message.
/// Flattens FileEdit fields to avoid nested value type complexity.
@Model
public final class ToolCallRecord {
    @Attribute(.unique) public var id: String
    public var message: Message?
    public var name: String
    public var input: String?
    public var output: String?
    public var status: String // pending, running, succeeded, failed, denied
    public var statusDetail: String? // detail when status is failed

    // FileEdit flattened
    public var editPath: String?
    public var editOldText: String?
    public var editNewText: String?

    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: String,
        message: Message? = nil,
        name: String,
        input: String? = nil,
        output: String? = nil,
        status: String = "pending",
        statusDetail: String? = nil,
        editPath: String? = nil,
        editOldText: String? = nil,
        editNewText: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.message = message
        self.name = name
        self.input = input
        self.output = output
        self.status = status
        self.statusDetail = statusDetail
        self.editPath = editPath
        self.editOldText = editOldText
        self.editNewText = editNewText
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

// MARK: - PermissionRequestRecord

/// A request for user permission to execute a tool.
/// Records the resolution (if any), who resolved it, and when.
@Model
public final class PermissionRequestRecord {
    @Attribute(.unique) public var id: String // provider's correlation id
    public var session: Session?
    public var toolCall: ToolCallRecord?
    public var toolName: String
    public var detail: String // complete, not truncated
    public var optionsJSON: String? // JSON-encoded PermissionOption array
    public var resolvedAt: Date?
    public var resolution: String? // the chosen option id
    public var resolvedBySource: String? // userAction or userConfiguredRule:{name}
    public var resolvedByOriginDetail: String? // rule name if applicable

    public init(
        id: String,
        session: Session? = nil,
        toolCall: ToolCallRecord? = nil,
        toolName: String,
        detail: String,
        optionsJSON: String? = nil
    ) {
        self.id = id
        self.session = session
        self.toolCall = toolCall
        self.toolName = toolName
        self.detail = detail
        self.optionsJSON = optionsJSON
    }
}

// MARK: - UsageRecord

/// Token usage for a single turn in a session.
/// Tracks input, output, cache read, and cache write tokens separately,
/// because pricing differs for each.
@Model
public final class UsageRecord {
    @Attribute(.unique) public var id: UUID
    public var session: Session?
    public var sequenceNumber: Int // which turn in the session
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var contextWindowUsed: Int?
    public var contextWindowTotal: Int?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        session: Session? = nil,
        sequenceNumber: Int,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        contextWindowUsed: Int? = nil,
        contextWindowTotal: Int? = nil
    ) {
        self.id = id
        self.session = session
        self.sequenceNumber = sequenceNumber
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.contextWindowUsed = contextWindowUsed
        self.contextWindowTotal = contextWindowTotal
        self.recordedAt = Date()
    }
}

// MARK: - PricingEntry

/// A pricing entry for a model's token costs.
/// Prices are per 1M tokens. Missing prices mean the cost is unknown (shown as such in UI).
@Model
public final class PricingEntry {
    @Attribute(.unique) public var id: UUID
    public var provider: String
    public var model: String
    public var inputPrice: Double? // per 1M tokens
    public var outputPrice: Double?
    public var cacheReadPrice: Double?
    public var cacheWritePrice: Double?
    public var tableVersion: Int
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        provider: String,
        model: String,
        inputPrice: Double? = nil,
        outputPrice: Double? = nil,
        cacheReadPrice: Double? = nil,
        cacheWritePrice: Double? = nil,
        tableVersion: Int = 1
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.cacheReadPrice = cacheReadPrice
        self.cacheWritePrice = cacheWritePrice
        self.tableVersion = tableVersion
        self.recordedAt = Date()
    }
}
