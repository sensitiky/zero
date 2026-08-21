import Foundation
import SwiftData

/// Persistence store for Zero sessions and transcript history.
///
/// ModelContext is not Sendable, so all persistence operations run on @MainActor.
/// This keeps the API simple: callers must orchestrate Sendability from above, but the store itself
/// is straightforward and makes no promises about async/await boundaries. If cross-thread access
/// becomes a real constraint later, that's a signal to reconsider the architecture, not to hide it
/// behind a protocol or an actor that pretends the problem went away.
@MainActor
final class Store {
    private let container: ModelContainer?
    private let context: ModelContext

    /// Initialize with a ModelContainer.
    /// Pass nil to use an in-memory container (useful for testing).
    init(modelContainer: ModelContainer? = nil) throws {
        if let modelContainer = modelContainer {
            self.container = nil
            self.context = modelContainer.mainContext
        } else {
            // In-memory container for testing
            let schema = Schema([
                Repository.self,
                Session.self,
                Message.self,
                ToolCallRecord.self,
                PermissionRequestRecord.self,
                UsageRecord.self,
                PricingEntry.self,
            ])
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let newContainer = try ModelContainer(for: schema, configurations: [config])
            self.container = newContainer
            self.context = newContainer.mainContext
        }
    }

    // MARK: - Repository

    func createRepository(path: String, name: String, defaultBranch: String) throws -> Repository {
        let repo = Repository(path: path, name: name, defaultBranch: defaultBranch)
        context.insert(repo)
        try context.save()
        return repo
    }

    // MARK: - Session

    func createSession(
        repository: Repository?,
        provider: String,
        model: String,
        worktreePath: String,
        branch: String,
        providerSessionId: String? = nil
    ) throws -> Session {
        let session = Session(
            repository: repository,
            provider: provider,
            model: model,
            worktreePath: worktreePath,
            branch: branch,
            providerSessionId: providerSessionId
        )
        context.insert(session)
        try context.save()
        return session
    }

    func updateSessionState(_ session: Session, state: String) throws {
        session.state = state
        try context.save()
    }

    func updateSessionError(_ session: Session, message: String) throws {
        session.state = "error"
        session.errorMessage = message
        try context.save()
    }

    func markSessionStarted(_ session: Session) throws {
        session.state = "running"
        session.startedAt = Date()
        try context.save()
    }

    func markSessionFinished(_ session: Session, state: String = "finished") throws {
        session.state = state
        session.endedAt = Date()
        try context.save()
    }

    func listSessions() throws -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchSession(id: UUID) throws -> Session? {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.includePendingChanges = true
        let sessions = try context.fetch(descriptor)
        return sessions.first
    }

    // MARK: - Message

    /// Append a message to a session.
    /// Assigns the next sequence number automatically.
    func appendMessage(
        to session: Session,
        role: String,
        content: String
    ) throws -> Message {
        let nextSeq = (session.messages.map { $0.sequenceNumber }.max() ?? -1) + 1
        let message = Message(
            session: session,
            role: role,
            content: content,
            sequenceNumber: nextSeq
        )
        context.insert(message)
        session.messages.append(message)
        try context.save()
        return message
    }

    // MARK: - ToolCall

    /// Append a tool call to a message.
    func appendToolCall(
        to message: Message,
        id: String,
        name: String,
        input: String?,
        status: String = "pending"
    ) throws -> ToolCallRecord {
        let toolCall = ToolCallRecord(
            id: id,
            message: message,
            name: name,
            input: input,
            status: status
        )
        context.insert(toolCall)
        message.toolCalls.append(toolCall)
        try context.save()
        return toolCall
    }

    /// Update a tool call's output and status.
    func updateToolCall(
        _ toolCall: ToolCallRecord,
        output: String?,
        status: String,
        statusDetail: String? = nil
    ) throws {
        toolCall.output = output
        toolCall.status = status
        toolCall.statusDetail = statusDetail
        try context.save()
    }

    /// Update tool call with file edit details.
    func updateToolCallEdit(
        _ toolCall: ToolCallRecord,
        path: String,
        oldText: String?,
        newText: String?
    ) throws {
        toolCall.editPath = path
        toolCall.editOldText = oldText
        toolCall.editNewText = newText
        try context.save()
    }

    /// Update tool call timing.
    func updateToolCallTiming(
        _ toolCall: ToolCallRecord,
        startedAt: Date?,
        endedAt: Date?
    ) throws {
        toolCall.startedAt = startedAt
        toolCall.endedAt = endedAt
        try context.save()
    }

    // MARK: - UsageRecord

    /// Append a usage record to a session.
    /// Assigns the next sequence number automatically.
    func appendUsageRecord(
        to session: Session,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        contextWindowUsed: Int?,
        contextWindowTotal: Int?
    ) throws -> UsageRecord {
        let nextSeq = (session.usageRecords.map { $0.sequenceNumber }.max() ?? -1) + 1
        let record = UsageRecord(
            session: session,
            sequenceNumber: nextSeq,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            contextWindowUsed: contextWindowUsed,
            contextWindowTotal: contextWindowTotal
        )
        context.insert(record)
        session.usageRecords.append(record)
        try context.save()
        return record
    }

    // MARK: - PermissionRequest

    /// Create a permission request for a session.
    func createPermissionRequest(
        id: String,
        session: Session,
        toolCall: ToolCallRecord?,
        toolName: String,
        detail: String,
        optionsJSON: String?
    ) throws -> PermissionRequestRecord {
        let request = PermissionRequestRecord(
            id: id,
            session: session,
            toolCall: toolCall,
            toolName: toolName,
            detail: detail,
            optionsJSON: optionsJSON
        )
        context.insert(request)
        session.permissionRequests.append(request)
        try context.save()
        return request
    }

    /// Resolve a permission request.
    /// Persists the resolution, the origin (userAction or rule name), and the timestamp.
    func resolvePermissionRequest(
        _ request: PermissionRequestRecord,
        resolution: String,
        source: String, // "userAction" or "userConfiguredRule:{name}"
        originDetail: String? = nil
    ) throws {
        request.resolution = resolution
        request.resolvedBySource = source
        request.resolvedByOriginDetail = originDetail
        request.resolvedAt = Date()
        try context.save()
    }

    func fetchPermissionRequest(id: String) throws -> PermissionRequestRecord? {
        var descriptor = FetchDescriptor<PermissionRequestRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.includePendingChanges = true
        let requests = try context.fetch(descriptor)
        return requests.first
    }

    // MARK: - PricingEntry

    /// Upsert a pricing entry (find by provider+model, update or create).
    func setPricingEntry(
        provider: String,
        model: String,
        inputPrice: Double?,
        outputPrice: Double?,
        cacheReadPrice: Double?,
        cacheWritePrice: Double?,
        tableVersion: Int
    ) throws {
        let predicate = #Predicate<PricingEntry> { $0.provider == provider && $0.model == model }
        var descriptor = FetchDescriptor<PricingEntry>(predicate: predicate)
        descriptor.includePendingChanges = true
        let existing = try context.fetch(descriptor)

        if let entry = existing.first {
            entry.inputPrice = inputPrice
            entry.outputPrice = outputPrice
            entry.cacheReadPrice = cacheReadPrice
            entry.cacheWritePrice = cacheWritePrice
            entry.tableVersion = tableVersion
            entry.recordedAt = Date()
        } else {
            let entry = PricingEntry(
                provider: provider,
                model: model,
                inputPrice: inputPrice,
                outputPrice: outputPrice,
                cacheReadPrice: cacheReadPrice,
                cacheWritePrice: cacheWritePrice,
                tableVersion: tableVersion
            )
            context.insert(entry)
        }
        try context.save()
    }

    /// Fetch pricing for a provider+model pair.
    /// Returns nil if not found. Distinguishable from zero price.
    func fetchPricingEntry(provider: String, model: String) throws -> PricingEntry? {
        let predicate = #Predicate<PricingEntry> { $0.provider == provider && $0.model == model }
        var descriptor = FetchDescriptor<PricingEntry>(predicate: predicate)
        descriptor.includePendingChanges = true
        let entries = try context.fetch(descriptor)
        return entries.first
    }
}
