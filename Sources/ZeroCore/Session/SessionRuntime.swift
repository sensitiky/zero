import Foundation
import SwiftData

/// Manages a single agent session: creation, event processing, persistence, and resumption.
///
/// The runtime is a plain actor (not @MainActor), so NDJSON parsing and decoding happen on
/// its own thread, avoiding main-thread stutter. Only batched persistence hops to the main actor.
public actor SessionRuntime {
    /// Configuration for creating a new session.
    public struct CreationConfig: Sendable {
        public var repository: URL  // path to the git repository
        public var provider: ProviderDescriptor
        public var model: String
        public var prompt: String
        public var resumeSessionId: String?  // if resuming, the provider's session id

        public init(
            repository: URL,
            provider: ProviderDescriptor,
            model: String,
            prompt: String,
            resumeSessionId: String? = nil
        ) {
            self.repository = repository
            self.provider = provider
            self.model = model
            self.prompt = prompt
            self.resumeSessionId = resumeSessionId
        }
    }

    /// Reasons creation might fail.
    public enum CreationError: Error, Sendable, CustomStringConvertible {
        /// Repository is dirty and cannot be used for a session.
        case repositoryIsDirty(path: String)
        /// Provider could not be resolved or started.
        case providerError(String)
        /// Git operation failed.
        case gitError(String)
        /// Store operation failed.
        case persistenceError(String)
        /// Process failed to start.
        case processError(String)

        public var description: String {
            switch self {
            case .repositoryIsDirty(let path):
                return "Repository at \(path) has uncommitted changes"
            case .providerError(let msg):
                return "Provider: \(msg)"
            case .gitError(let msg):
                return "Git: \(msg)"
            case .persistenceError(let msg):
                return "Persistence: \(msg)"
            case .processError(let msg):
                return "Process: \(msg)"
            }
        }
    }

    // Session is MainActor-confined; we only store its ID for safe cross-actor use.
    private let sessionID: UUID

    /// The session's identity, readable without an actor hop.
    ///
    /// `nonisolated` for the same reason as `transcript`: it is an immutable `Sendable` value, and a
    /// caller keying UI state by it should not pay a hop per lookup.
    public nonisolated var id: UUID { sessionID }
    private let process: AgentProcess
    private let store: Store
    private let gitService: GitService
    /// Existential, not `ClaudeCodeDecoder`.
    ///
    /// A runtime named after one provider's decoder can only ever drive that provider, which is
    /// the opposite of FR-13. It also made the off-main-thread guarantee untestable, because no
    /// spy could be injected to observe where decoding actually runs.
    private var decoder: any ProtocolDecoder
    private var encoder: any ProtocolEncoder
    private let providerRegistry: ProviderRegistry

    private var consumeTask: Task<Void, Never>?
    private var currentState: SessionState = .idle
    private var lastFlush = Date()
    private let flushDebounceInterval: TimeInterval = 0.5

    /// The normalized transcript, for a UI to render incrementally.
    ///
    /// `nonisolated` because `AsyncStream` is already `Sendable`: a consumer should be able to
    /// subscribe without awaiting the actor, the same way `AgentProcess.output` works.
    public nonisolated let transcript: AsyncStream<AgentEvent>
    private nonisolated let transcriptContinuation: AsyncStream<AgentEvent>.Continuation

    // MARK: - Initialization

    public init(
        sessionID: UUID,
        process: AgentProcess,
        store: Store,
        gitService: GitService,
        decoder: any ProtocolDecoder,
        encoder: any ProtocolEncoder,
        providerRegistry: ProviderRegistry
    ) {
        self.sessionID = sessionID
        self.process = process
        self.store = store
        self.gitService = gitService
        self.decoder = decoder
        self.encoder = encoder
        self.providerRegistry = providerRegistry

        // Capture continuation for async stream
        var captured: AsyncStream<AgentEvent>.Continuation!
        self.transcript = AsyncStream { captured = $0 }
        self.transcriptContinuation = captured

        currentState = .idle
    }

    // MARK: - Creation

    /// Creates a new session, checks the repository, creates a worktree, and starts the process.
    ///
    /// - Parameter config: Configuration for the session.
    /// - Returns: A runtime ready to process events.
    /// - Throws: `CreationError` if any step fails. On failure, the worktree is cleaned up.
    public static func create(
        with config: CreationConfig,
        store: Store,
        providerRegistry: ProviderRegistry
    ) async throws -> SessionRuntime {
        // Initialize git service for the repository
        let gitService: GitService
        do {
            gitService = try GitService(repositoryPath: config.repository)
        } catch let error as GitError {
            throw CreationError.gitError(String(describing: error))
        } catch {
            throw CreationError.gitError(String(describing: error))
        }

        // Check if repository is dirty — surface this rather than silently deciding
        let isDirty: Bool
        do {
            isDirty = try await gitService.isDirty()
        } catch let error as GitError {
            throw CreationError.gitError(String(describing: error))
        } catch {
            throw CreationError.gitError(String(describing: error))
        }

        if isDirty {
            throw CreationError.repositoryIsDirty(path: config.repository.path)
        }

        // Create the worktree
        let (worktreePath, branchName): (URL, String)
        do {
            (worktreePath, branchName) = try await gitService.createWorktree(from: config.prompt)
        } catch let error as GitError {
            throw CreationError.gitError(String(describing: error))
        } catch {
            throw CreationError.gitError(String(describing: error))
        }

        // Build process configuration first (before MainActor work)
        let processConfig: AgentProcess.Configuration
        do {
            processConfig = try providerRegistry.configuration(
                for: config.provider,
                workingDirectory: worktreePath
            )
        } catch {
            try? await gitService.removeWorktree(at: worktreePath, removeBranch: true)
            throw CreationError.providerError(String(describing: error))
        }

        // Create and start the process
        let process = AgentProcess(configuration: processConfig)
        do {
            try await process.start()
        } catch {
            try? await gitService.removeWorktree(at: worktreePath, removeBranch: true)
            throw CreationError.processError(String(describing: error))
        }

        // Do all session creation and runtime setup on MainActor
        let sessionID = try await MainActor.run {
            // Create the session
            let session = try store.createSession(
                repository: nil,  // repository relationship optional for now
                provider: config.provider.id,
                model: config.model,
                worktreePath: worktreePath.path,
                branch: branchName,
                providerSessionId: config.resumeSessionId
            )

            // Mark session as started
            try store.markSessionStarted(session)
            return session.id
        }

        // Create the runtime with only the session ID
        let runtime = SessionRuntime(
            sessionID: sessionID,
            process: process,
            store: store,
            gitService: gitService,
            decoder: ClaudeCodeDecoder(),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: providerRegistry
        )

        try await runtime.start()
        // The opening prompt was previously never sent: creation launched the CLI and told it
        // nothing. It goes through the same `send` as every later turn.
        try await runtime.send(config.prompt)

        return runtime
    }

    // MARK: - Resumption

    /// Reopens a persisted session.
    ///
    /// When the provider reported its own session id — `system/init` carries it, and it is persisted
    /// the moment it arrives — the CLI is relaunched with `--resume <id>` and keeps its memory of the
    /// conversation. When it did not, the session comes back read-only: the transcript is intact and
    /// readable, but the agent is not resumed, because handing a provider an id it never issued is
    /// how you get a confidently wrong session rather than an honest empty one.
    public static func resume(
        sessionID: UUID,
        store: Store,
        providerRegistry: ProviderRegistry
    ) async throws -> SessionRuntime {
        struct Restored: Sendable {
            let worktree: URL
            let repositoryRoot: URL
            let providerSessionID: String?
            let provider: String
        }

        let restored: Restored = try await MainActor.run {
            guard let session = try store.fetchSession(id: sessionID) else {
                throw CreationError.persistenceError("Session not found")
            }
            let worktree = URL(fileURLWithPath: session.worktreePath)
            return Restored(
                worktree: worktree,
                repositoryRoot: worktree.deletingLastPathComponent().deletingLastPathComponent(),
                providerSessionID: session.providerSessionId,
                provider: session.provider
            )
        }

        let gitService: GitService
        do {
            gitService = try GitService(repositoryPath: restored.repositoryRoot)
        } catch {
            throw CreationError.gitError(String(describing: error))
        }

        // Only Claude Code has a resume flag verified against the real CLI. Anything else stays
        // read-only rather than being launched with a guessed argument.
        let descriptor: ProviderDescriptor? = restored.provider == ProviderDescriptor.claude.id
            || restored.provider == ProviderDescriptor.claude.displayName
            ? ProviderDescriptor.claude
            : nil

        guard let descriptor, let providerSessionID = restored.providerSessionID else {
            return try await readOnly(
                sessionID: sessionID,
                worktree: restored.worktree,
                store: store,
                gitService: gitService,
                providerRegistry: providerRegistry
            )
        }

        let configuration: AgentProcess.Configuration
        do {
            configuration = try providerRegistry.configuration(
                for: descriptor,
                workingDirectory: restored.worktree,
                extraArguments: ["--resume", providerSessionID]
            )
        } catch {
            throw CreationError.providerError(String(describing: error))
        }

        let runtime = SessionRuntime(
            sessionID: sessionID,
            process: AgentProcess(configuration: configuration),
            store: store,
            gitService: gitService,
            decoder: ClaudeCodeDecoder(),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: providerRegistry
        )
        try await runtime.start()
        return runtime
    }

    /// A session reopened for reading only, because no resume was possible.
    ///
    /// It holds no live process, so `send` throws rather than appearing to work.
    private static func readOnly(
        sessionID: UUID,
        worktree: URL,
        store: Store,
        gitService: GitService,
        providerRegistry: ProviderRegistry
    ) async throws -> SessionRuntime {
        let idle = AgentProcess(
            configuration: AgentProcess.Configuration(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: [:],
                workingDirectory: worktree
            )
        )
        let runtime = SessionRuntime(
            sessionID: sessionID,
            process: idle,
            store: store,
            gitService: gitService,
            decoder: ClaudeCodeDecoder(),
            encoder: ClaudeCodeEncoder(),
            providerRegistry: providerRegistry
        )
        await runtime.markReadOnly()
        return runtime
    }

    /// Marks a reopened session as finished: the history is there, the agent is not.
    private func markReadOnly() {
        currentState = .finished
        transcriptContinuation.finish()
    }

    // MARK: - Public Interface

    /// The session's current state.
    public var state: SessionState {
        currentState
    }

    /// Starts the runtime: sets state to running and begins consuming output.
    /// Launches the provider process if it is not already running, then consumes its output until
    /// the session ends.
    ///
    /// It starts the process on purpose: an earlier version only consumed `process.output`, so a
    /// caller that built a runtime directly waited forever on a subprocess nobody had launched.
    /// A `start()` that does not start is a trap.
    public func start() async throws {
        if await !process.isRunning {
            try await process.start()
        }
        currentState = .running
        // Consumption runs detached so `start()` returns promptly. Awaiting it inline made session
        // creation block until the agent's entire stream ended, which is the opposite of what a
        // caller wants: it needs a live runtime to send turns to and a transcript to render.
        consumeTask = Task { [weak self] in
            await self?.consumeProcessOutput()
        }
    }

    /// Sends a turn.
    ///
    /// The single path a prompt takes, opening or follow-up. Two paths drift, and then the second
    /// message is formatted differently from the first for reasons nobody remembers.
    public func send(_ text: String) async throws {
        guard await process.isRunning else { throw CreationError.providerError("session is not running") }
        for record in try encoder.encodePrompt(text) {
            try await process.send(record)
        }
        currentState = .running
    }

    /// Cancels the turn in progress, leaving the session alive.
    ///
    /// Providers with an in-band cancel get one, because it tells the agent why it stopped. The rest
    /// fall back to SIGINT — see `AgentProcess.interrupt()` for why that is not SIGTERM.
    public func cancelTurn() async {
        // `encodeCancel` returns nil when the protocol has no cancel record — Claude Code's does
        // not — and the double optional here is that nil versus an encoding failure.
        if let records = (try? encoder.encodeCancel()) ?? nil, !records.isEmpty {
            for record in records {
                try? await process.send(record)
            }
        } else {
            await process.interrupt()
        }
    }

    /// Waits for the session to finish. For tests and for orderly shutdown.
    public func waitUntilFinished() async {
        await consumeTask?.value
    }

    // MARK: - Event Processing

    /// Consumes the process output stream, decodes events on the actor thread, and yields to callers.
    /// This method runs on the runtime's own actor, NOT the main thread.
    private func consumeProcessOutput() async {
        var pendingEvents: [AgentEvent] = []
        var lastFlushTime = Date()

        for await output in process.output {
            switch output {
            case .record(let data):
                // Decode happens HERE, on the runtime's actor thread, not main
                let events = decoder.decode(line: data)

                for event in events {
                    // Yield immediately (non-blocking)
                    transcriptContinuation.yield(event)

                    // Queue event for persistence
                    pendingEvents.append(event)

                    // Drive state transitions and check for turn boundaries
                    switch event {
                    case .turnEnded:
                        // Turn boundary: flush immediately
                        await persistAndFlush(pendingEvents)
                        pendingEvents.removeAll()
                        lastFlushTime = Date()
                        currentState = .running  // ready for next turn

                    case .permissionRequested:
                        currentState = .waitingPermission

                    case .failed(let reason):
                        currentState = .error(reason)

                    default:
                        break
                    }
                }

                // Debounce flush: every 0.5s or on turn boundary
                if Date().timeIntervalSince(lastFlushTime) > flushDebounceInterval && !pendingEvents.isEmpty {
                    await persistAndFlush(pendingEvents)
                    pendingEvents.removeAll()
                    lastFlushTime = Date()
                }

            case .diagnostic:
                // Logging/debug output; not part of the transcript
                break

            case .exited(let code, _):
                // Flush any pending events
                if !pendingEvents.isEmpty {
                    await persistAndFlush(pendingEvents)
                }

                // Mark session as error if it didn't finish cleanly
                if currentState == .running || currentState == .waitingPermission {
                    let errorMsg = "Process exited with code \(code)"
                    currentState = .error(errorMsg)
                    await MainActor.run {
                        if let session = try? store.fetchSession(id: sessionID) {
                            try? store.updateSessionError(session, message: errorMsg)
                        }
                    }
                } else {
                    currentState = .finished
                    await MainActor.run {
                        if let session = try? store.fetchSession(id: sessionID) {
                            try? store.markSessionFinished(session)
                        }
                    }
                }

                transcriptContinuation.finish()
                return

            case .streamFailure(let error):
                // Stream error
                currentState = .error(error)
                await MainActor.run {
                    if let session = try? store.fetchSession(id: sessionID) {
                        try? store.updateSessionError(session, message: error)
                    }
                }
                transcriptContinuation.finish()
                return
            }
        }
    }

    /// Yields the session's history and finishes the stream (for read-only resume).
    private func yieldHistoryAndFinish() async {
        currentState = .finished
        transcriptContinuation.finish()
    }

    // MARK: - Persistence

    /// Persists a batch of events to the store and flushes to disk.
    /// This is the ONLY place persistence happens, and it uses ONE MainActor.run hop
    /// to fetch the session, do all appends, and call flush().
    private func persistAndFlush(_ events: [AgentEvent]) async {
        // All store operations in one MainActor hop
        await MainActor.run {
            // Fetch the session by ID (only reference within MainActor context)
            guard let session = try? store.fetchSession(id: sessionID) else { return }

            var pendingMessage: Message?
            var pendingToolCalls: [String: ToolCallRecord] = [:]

            for event in events {
                switch event {
                case .sessionReady(let providerSessionID, _):
                    // Written immediately: resume needs this id, and a turn that crashes must not
                    // take it with it.
                    try? store.recordProviderSessionID(providerSessionID, for: session)

                case .rateLimit:
                    // Surfaced on the transcript for the UI; nothing to persist.
                    break

                case .textDelta(let text):
                    if pendingMessage == nil {
                        pendingMessage = try? store.appendMessage(to: session, role: "assistant", content: text)
                    } else {
                        pendingMessage?.content.append(text)
                    }

                case .thinkingDelta:
                    // Internal; not persisted
                    break

                case .toolCall(let toolCall):
                    var message = pendingMessage
                    if message == nil {
                        message = try? store.appendMessage(
                            to: session,
                            role: "assistant",
                            content: ""
                        )
                    }
                    if let message = message {
                        pendingMessage = message

                        if let existing = pendingToolCalls[toolCall.id] {
                            // Update existing
                            switch toolCall.status {
                            case .pending:
                                break
                            case .running:
                                existing.status = "running"
                            case .succeeded:
                                existing.output = toolCall.output
                                existing.status = "succeeded"
                                existing.endedAt = toolCall.endedAt
                            case .failed(let detail):
                                existing.output = detail
                                existing.status = "failed"
                                existing.statusDetail = detail
                                existing.endedAt = toolCall.endedAt
                            case .denied:
                                existing.status = "denied"
                                existing.endedAt = toolCall.endedAt
                            }
                            if let edit = toolCall.edit {
                                existing.editPath = edit.path
                                existing.editOldText = edit.oldText
                                existing.editNewText = edit.newText
                            }
                        } else {
                            // New tool call
                            let statusStr: String
                            switch toolCall.status {
                            case .pending: statusStr = "pending"
                            case .running: statusStr = "running"
                            case .succeeded: statusStr = "succeeded"
                            case .failed: statusStr = "failed"
                            case .denied: statusStr = "denied"
                            }

                            if let record = try? store.appendToolCall(
                                to: message,
                                id: toolCall.id,
                                name: toolCall.name,
                                input: toolCall.input,
                                status: statusStr
                            ) {
                                if let edit = toolCall.edit {
                                    try? store.updateToolCallEdit(
                                        record,
                                        path: edit.path,
                                        oldText: edit.oldText,
                                        newText: edit.newText
                                    )
                                }
                                pendingToolCalls[toolCall.id] = record
                            }
                        }
                    }

                case .usage(let usage):
                    _ = try? store.appendUsageRecord(
                        to: session,
                        model: usage.model,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheReadTokens: usage.cacheReadTokens,
                        cacheWriteTokens: usage.cacheWriteTokens,
                        contextWindowUsed: usage.contextWindowUsed,
                        contextWindowTotal: usage.contextWindowTotal
                    )

                case .thinkingProgress:
                    // Running estimate; separate from usage
                    break

                case .permissionRequested(let request):
                    let toolCall = pendingToolCalls.values.first
                    let optionsJSON: String?
                    do {
                        let optionsArray = request.options.map { o -> [String: String] in
                            let kindStr: String
                            switch o.kind {
                            case .allowOnce: kindStr = "allowOnce"
                            case .allowAlways: kindStr = "allowAlways"
                            case .denyOnce: kindStr = "denyOnce"
                            case .denyAlways: kindStr = "denyAlways"
                            }
                            return ["id": o.id, "kind": kindStr, "label": o.label]
                        }
                        if let data = try? JSONSerialization.data(
                            withJSONObject: optionsArray,
                            options: [.sortedKeys]
                        ) {
                            optionsJSON = String(data: data, encoding: .utf8)
                        } else {
                            optionsJSON = nil
                        }
                    }
                    _ = try? store.createPermissionRequest(
                        id: request.id,
                        session: session,
                        toolCall: toolCall,
                        toolName: request.toolName,
                        detail: request.detail,
                        optionsJSON: optionsJSON
                    )

                case .turnStarted:
                    pendingMessage = nil
                    pendingToolCalls.removeAll()

                case .turnEnded:
                    pendingMessage = nil
                    pendingToolCalls.removeAll()

                case .plan, .unrecognized, .failed:
                    break
                }
            }

            // Single flush for the batch
            try? store.flush()
        }
    }

}
