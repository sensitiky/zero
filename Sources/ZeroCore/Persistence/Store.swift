import Foundation
import SwiftData

/// Reasons a `Store` call can fail beyond what SwiftData itself throws.
public enum StoreError: Error, Sendable, Equatable {
    /// A `Message` with no `session` was handed to a call that needs one — every message this
    /// type creates sets it, so seeing this means a caller built one by hand.
    case detachedMessage
}

/// Persistence store for Zero sessions and transcript history.
///
/// ModelContext is not Sendable, so all persistence operations run on @MainActor.
/// This keeps the API simple: callers must orchestrate Sendability from above, but the store itself
/// is straightforward and makes no promises about async/await boundaries. If cross-thread access
/// becomes a real constraint later, that's a signal to reconsider the architecture, not to hide it
/// behind a protocol or an actor that pretends the problem went away.
@MainActor
public final class Store {

    /// Records the id the provider assigned to this session.
    ///
    /// Resume depends on handing this exact value back to the provider, so it is written as soon as
    /// the provider reports it rather than at the end of a turn that may never finish cleanly.
    public func recordProviderSessionID(_ id: String, for session: Session) throws {
        guard session.providerSessionId != id else { return }
        session.providerSessionId = id
        try flush()
    }

    /// Writes pending appends to disk.
    ///
    /// Appends do not flush individually: a `save()` per record measured 27.6 ms at p50, which is
    /// 275 s for a 10k-message session. Reads are unaffected — fetching a 10k-message history takes
    /// 1.1 ms — so the cost was never the store, it was a flush policy nobody chose on purpose.
    /// The session runtime flushes on turn boundaries and on a short debounce, which bounds what a
    /// crash can lose to the last few hundred milliseconds instead of making every message wait.
    public func flush() throws {
        guard context.hasChanges else { return }
        try context.save()
    }
    private let container: ModelContainer?
    private let context: ModelContext

    /// The full model list, in one place, so the in-memory (tests) and on-disk (production)
    /// containers can never drift apart by one of them forgetting a newly added model.
    public static let schema = Schema([
        Repository.self,
        Session.self,
        Message.self,
        ToolCallRecord.self,
        PermissionRequestRecord.self,
        UsageRecord.self,
        PricingEntry.self,
        PlanSnapshotRecord.self,
    ])

    /// Initialize with a ModelContainer.
    /// Pass nil to use an in-memory container (useful for testing).
    public init(modelContainer: ModelContainer? = nil) throws {
        if let modelContainer = modelContainer {
            // Retained even when injected: the context holds no strong reference back, so dropping
            // the container here leaves `context` pointing at a deallocated store.
            self.container = modelContainer
            self.context = modelContainer.mainContext
        } else {
            // In-memory container for testing. Deliberately not the production default — see
            // `defaultModelContainer(baseDirectory:)` for that — so this meaning never changes
            // out from under the ~20 call sites (mostly tests) that already rely on it.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let newContainer = try ModelContainer(for: Self.schema, configurations: [config])
            self.container = newContainer
            self.context = newContainer.mainContext
        }
    }

    /// The on-disk container production uses: `{baseDirectory}/{bundle id}/Zero.store`, created
    /// if it doesn't exist yet.
    ///
    /// Application Support, not `Bundle.main.bundleURL` — the app bundle is replaced whole on
    /// every update/reinstall via the `.dmg`; Application Support survives that, which is the
    /// entire point (see `docs/prds/006-persistent-projects-sessions/PRD.md`). `baseDirectory`
    /// defaults to the real Application Support URL and exists as a parameter only so tests can
    /// point this at a temp directory instead of the user's real one.
    public static func defaultModelContainer(
        baseDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
    ) throws -> ModelContainer {
        let bundleID = Bundle.main.bundleIdentifier ?? "the.stool.zero"
        let directory = baseDirectory.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("Zero.store")
        let config = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: Self.schema, configurations: [config])
    }

    // MARK: - Repository

    public func createRepository(path: String, name: String, defaultBranch: String) throws -> Repository {
        let repo = Repository(path: path, name: name, defaultBranch: defaultBranch)
        context.insert(repo)
        try context.save()
        return repo
    }

    /// Finds the repository at `path`, or creates it. A session started twice in the same
    /// checkout, or a folder re-added as a project, must land on the same row — not a duplicate
    /// one every time.
    public func upsertRepository(path: String, name: String, defaultBranch: String) throws -> Repository {
        let predicate = #Predicate<Repository> { $0.path == path }
        var descriptor = FetchDescriptor<Repository>(predicate: predicate)
        descriptor.includePendingChanges = true
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        return try createRepository(path: path, name: name, defaultBranch: defaultBranch)
    }

    public func listRepositories() throws -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Session

    public func createSession(
        id: UUID = UUID(),
        repository: Repository?,
        provider: String,
        model: String,
        worktreePath: String,
        branch: String,
        providerSessionId: String? = nil,
        permissionMode: String = "ask"
    ) throws -> Session {
        let session = Session(
            id: id,
            repository: repository,
            provider: provider,
            model: model,
            worktreePath: worktreePath,
            branch: branch,
            providerSessionId: providerSessionId,
            permissionMode: permissionMode
        )
        context.insert(session)
        try context.save()
        return session
    }

    /// Changes a session's permission mode. The caller is responsible for relaunching a live
    /// runtime with the new mode — this only persists the choice (see `SessionCoordinator.
    /// setPermissionMode`).
    public func updatePermissionMode(_ session: Session, mode: PermissionMode) throws {
        session.permissionMode = mode.rawValue
        try context.save()
    }

    public func updateSessionState(_ session: Session, state: String) throws {
        session.state = state
        try context.save()
    }

    public func updateSessionError(_ session: Session, message: String) throws {
        session.state = "error"
        session.errorMessage = message
        try context.save()
    }

    public func markSessionStarted(_ session: Session) throws {
        session.state = "running"
        session.startedAt = Date()
        try context.save()
    }

    public func markSessionFinished(_ session: Session, state: String = "finished") throws {
        session.state = state
        session.endedAt = Date()
        try context.save()
    }

    public func listSessions() throws -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func fetchSession(id: UUID) throws -> Session? {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.includePendingChanges = true
        let sessions = try context.fetch(descriptor)
        return sessions.first
    }

    // MARK: - Message

    /// Append a message to a session.
    /// Assigns the next entry sequence number automatically — shared with tool calls and plan
    /// snapshots, so a fetch can interleave all three back into one chronological transcript.
    public func appendMessage(
        to session: Session,
        role: String,
        content: String
    ) throws -> Message {
        let nextSeq = session.nextEntrySequence
        session.nextEntrySequence += 1
        let message = Message(
            session: session,
            role: role,
            content: content,
            sequenceNumber: nextSeq
        )
        context.insert(message)
        return message
    }

    // MARK: - ToolCall

    /// Append a tool call to a message. Drawn from the same session-wide counter `appendMessage`
    /// uses — see its doc comment.
    public func appendToolCall(
        to message: Message,
        id: String,
        name: String,
        input: String?,
        status: String = "pending"
    ) throws -> ToolCallRecord {
        guard let session = message.session else {
            throw StoreError.detachedMessage
        }
        let nextSeq = session.nextEntrySequence
        session.nextEntrySequence += 1
        let toolCall = ToolCallRecord(
            id: id,
            message: message,
            name: name,
            input: input,
            status: status,
            sequenceNumber: nextSeq
        )
        context.insert(toolCall)
        message.toolCalls.append(toolCall)
        try context.save()
        return toolCall
    }

    /// Update a tool call's output and status.
    public func updateToolCall(
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
    public func updateToolCallEdit(
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
    public func updateToolCallTiming(
        _ toolCall: ToolCallRecord,
        startedAt: Date?,
        endedAt: Date?
    ) throws {
        toolCall.startedAt = startedAt
        toolCall.endedAt = endedAt
        try context.save()
    }

    // MARK: - PlanSnapshotRecord

    /// Append a plan snapshot to a session — the full, current `[PlanItem]` list, JSON-encoded.
    /// Drawn from the same session-wide counter `appendMessage` uses — see its doc comment.
    public func appendPlanSnapshot(to session: Session, itemsJSON: String) throws -> PlanSnapshotRecord {
        let nextSeq = session.nextEntrySequence
        session.nextEntrySequence += 1
        let snapshot = PlanSnapshotRecord(session: session, sequenceNumber: nextSeq, itemsJSON: itemsJSON)
        context.insert(snapshot)
        session.planSnapshots.append(snapshot)
        try context.save()
        return snapshot
    }

    // MARK: - UsageRecord

    /// Append a usage record to a session.
    /// Assigns the next sequence number automatically.
    public func appendUsageRecord(
        to session: Session,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        contextWindowUsed: Int?,
        contextWindowTotal: Int?
    ) throws -> UsageRecord {
        let nextSeq = session.nextUsageSequence
        session.nextUsageSequence += 1
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
        return record
    }

    // MARK: - PermissionRequest

    /// Create a permission request for a session.
    public func createPermissionRequest(
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
    public func resolvePermissionRequest(
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

    public func fetchPermissionRequest(id: String) throws -> PermissionRequestRecord? {
        var descriptor = FetchDescriptor<PermissionRequestRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.includePendingChanges = true
        let requests = try context.fetch(descriptor)
        return requests.first
    }

    // MARK: - PricingEntry

    /// Upsert a pricing entry (find by provider+model, update or create).
    public func setPricingEntry(
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
    public func fetchPricingEntry(provider: String, model: String) throws -> PricingEntry? {
        let predicate = #Predicate<PricingEntry> { $0.provider == provider && $0.model == model }
        var descriptor = FetchDescriptor<PricingEntry>(predicate: predicate)
        descriptor.includePendingChanges = true
        let entries = try context.fetch(descriptor)
        return entries.first
    }
}
