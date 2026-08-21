import Foundation
import SwiftData

// MARK: - Repository

/// A local git repository that can host worktrees.
@Model
final class Repository {
    @Attribute(.unique) var id: UUID
    var path: String
    var name: String
    var defaultBranch: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Session.repository)
    var sessions: [Session] = []

    init(id: UUID = UUID(), path: String, name: String, defaultBranch: String) {
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
final class Session {
    @Attribute(.unique) var id: UUID
    var repository: Repository?
    var provider: String
    var model: String
    var worktreePath: String
    var branch: String
    var state: String // idle, running, waitingPermission, error, finished
    var providerSessionId: String? // for resuming
    var createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var errorMessage: String?

    /// Monotonic counters for append ordering.
    ///
    /// Held on the session rather than derived from the collections: deriving `max + 1` means
    /// faulting every existing row on every append, which is O(n) per append and O(n²) per
    /// session. That cost is what an earlier revision of this file measured and mistook for
    /// SwiftData being unsuitable — see MEASUREMENTS.md.
    var nextMessageSequence: Int = 0
    var nextUsageSequence: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \UsageRecord.session)
    var usageRecords: [UsageRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PermissionRequestRecord.session)
    var permissionRequests: [PermissionRequestRecord] = []

    init(
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
final class Message {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var role: String // user, assistant, system
    var content: String
    var sequenceNumber: Int // stable ordering, not dependent on insertion or timestamps
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ToolCallRecord.message)
    var toolCalls: [ToolCallRecord] = []

    init(
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
final class ToolCallRecord {
    @Attribute(.unique) var id: String
    var message: Message?
    var name: String
    var input: String?
    var output: String?
    var status: String // pending, running, succeeded, failed, denied
    var statusDetail: String? // detail when status is failed

    // FileEdit flattened
    var editPath: String?
    var editOldText: String?
    var editNewText: String?

    var startedAt: Date?
    var endedAt: Date?

    init(
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
final class PermissionRequestRecord {
    @Attribute(.unique) var id: String // provider's correlation id
    var session: Session?
    var toolCall: ToolCallRecord?
    var toolName: String
    var detail: String // complete, not truncated
    var optionsJSON: String? // JSON-encoded PermissionOption array
    var resolvedAt: Date?
    var resolution: String? // the chosen option id
    var resolvedBySource: String? // userAction or userConfiguredRule:{name}
    var resolvedByOriginDetail: String? // rule name if applicable

    init(
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
final class UsageRecord {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var sequenceNumber: Int // which turn in the session
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var contextWindowUsed: Int?
    var contextWindowTotal: Int?
    var recordedAt: Date

    init(
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
final class PricingEntry {
    @Attribute(.unique) var id: UUID
    var provider: String
    var model: String
    var inputPrice: Double? // per 1M tokens
    var outputPrice: Double?
    var cacheReadPrice: Double?
    var cacheWritePrice: Double?
    var tableVersion: Int
    var recordedAt: Date

    init(
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
