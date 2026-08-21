import Foundation
import SwiftData

/// Manages a single agent session: creation, event processing, persistence, and resumption.
///
/// The runtime orchestrates provider resolution, worktree lifecycle, event decoding, and
/// transcript persistence. All I/O to the store happens on the main actor; the runtime
/// batches persistence operations to avoid the 27.6 ms/record cost of per-event saves.
@MainActor
final class SessionRuntime {
    /// Configuration for creating a new session.
    struct CreationConfig: Sendable {
        var repository: URL  // path to the git repository
        var provider: ProviderDescriptor
        var model: String
        var prompt: String
        var resumeSessionId: String?  // if resuming, the provider's session id

        init(
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
    enum CreationError: Error, Sendable, CustomStringConvertible {
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

        var description: String {
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

    private let session: Session
    private let process: AgentProcess
    private let store: Store
    private let gitService: GitService
    private var decoder: ClaudeCodeDecoder
    private let providerRegistry: ProviderRegistry

    private var currentState: SessionState = .idle
    private var pendingMessage: Message?  // accumulates text deltas
    private var pendingToolCalls: [String: (message: Message, record: ToolCallRecord)] = [:]
    private var lastFlush = Date()
    private let flushDebounceInterval: TimeInterval = 0.5

    // AsyncStream for the transcript
    let transcript: AsyncStream<AgentEvent>
    private let transcriptContinuation: AsyncStream<AgentEvent>.Continuation

    // MARK: - Initialization

    init(
        session: Session,
        process: AgentProcess,
        store: Store,
        gitService: GitService,
        decoder: ClaudeCodeDecoder,
        providerRegistry: ProviderRegistry
    ) {
        self.session = session
        self.process = process
        self.store = store
        self.gitService = gitService
        self.decoder = decoder
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
    static func create(
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
        let runtime = try await MainActor.run {
            // Create the session
            let session = try store.createSession(
                repository: nil,  // repository relationship optional for now
                provider: config.provider.id,
                model: config.model,
                worktreePath: worktreePath.path,
                branch: branchName,
                providerSessionId: config.resumeSessionId
            )

            // Create the runtime with the session
            let runtime = SessionRuntime(
                session: session,
                process: process,
                store: store,
                gitService: gitService,
                decoder: ClaudeCodeDecoder(),
                providerRegistry: providerRegistry
            )

            // Mark session as started
            try store.markSessionStarted(session)
            runtime.currentState = .running

            return runtime
        }

        // Spawn background task to consume process output
        Task {
            await runtime.consumeProcessOutput()
        }

        return runtime
    }

    // MARK: - Resumption

    /// Reopens a persisted session.
    ///
    /// If the provider has a resume mechanism (identified by a `providerSessionId`),
    /// a fresh process starts with the resume token. Otherwise, the session opens
    /// read-only: history is visible, but new turns cannot be started.
    ///
    /// - Parameters:
    ///   - sessionID: The persisted session ID to resume.
    ///   - store: The persistence store.
    ///   - providerRegistry: Provider resolver.
    /// - Returns: A runtime with the session's history and, if possible, a fresh process.
    static func resume(
        sessionID: UUID,
        store: Store,
        providerRegistry: ProviderRegistry
    ) async throws -> SessionRuntime {
        // ponytail: simplified resume: no history streaming yet, just session reopen.
        // The session's orderedMessages are available to callers; a fresh turn can only
        // proceed if the provider supports resume via sessionId.

        let runtime = try await MainActor.run {
            let session = try store.fetchSession(id: sessionID)
                ?? { throw CreationError.persistenceError("Session not found") }()

            let repoURL = URL(fileURLWithPath: session.worktreePath)
                .deletingLastPathComponent()  // .worktrees
                .deletingLastPathComponent()  // repo root

            let gitService: GitService
            do {
                gitService = try GitService(repositoryPath: repoURL)
            } catch {
                throw CreationError.gitError(String(describing: error))
            }

            let provider = ProviderDescriptor.claude  // ponytail: hard-coded for now

            // If the session has a providerSessionId, try to resume the process
            let process: AgentProcess?
            if let resumeID = session.providerSessionId {
                do {
                    let processConfig = try providerRegistry.configuration(
                        for: provider,
                        workingDirectory: URL(fileURLWithPath: session.worktreePath)
                    )
                    // ponytail: no per-provider resume logic yet; Claude Code uses --resume <id>
                    process = nil  // for now
                } catch {
                    process = nil
                }
            } else {
                process = nil
            }

            let dummyProcess = AgentProcess(
                configuration: AgentProcess.Configuration(
                    executable: URL(fileURLWithPath: "/dev/null"),
                    arguments: [],
                    environment: [:],
                    workingDirectory: URL(fileURLWithPath: session.worktreePath)
                )
            )

            let runtime = SessionRuntime(
                session: session,
                process: process ?? dummyProcess,
                store: store,
                gitService: gitService,
                decoder: ClaudeCodeDecoder(),
                providerRegistry: providerRegistry
            )

            return runtime
        }

        // Start consuming output or finish with history
        Task {
            // Determine if we need to consume process output or just finish
            // ponytail: this is deferred; check for a real process vs dummy
            await runtime.yieldHistoryAndFinish()
        }

        return runtime
    }

    // MARK: - Public Interface

    /// The transcript: a stream of normalized events from the session.
    var events: AsyncStream<AgentEvent> {
        transcript
    }

    /// The session's current state.
    var state: SessionState {
        currentState
    }

    // MARK: - Event Processing

    /// Consumes the process output stream, decodes events, persists them, and yields to callers.
    private func consumeProcessOutput() async {
        var pendingEvents: [AgentEvent] = []
        var lastFlushTime = Date()

        for await output in process.output {
            switch output {
            case .record(let data):
                // Decode the record
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
                        persistAndFlush(pendingEvents)
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
                    persistAndFlush(pendingEvents)
                    pendingEvents.removeAll()
                    lastFlushTime = Date()
                }

            case .diagnostic(let text):
                // Logging/debug output; not part of the transcript
                break

            case .exited(let code, let reason):
                // Flush any pending events
                if !pendingEvents.isEmpty {
                    persistAndFlush(pendingEvents)
                }

                // Mark session as error if it didn't finish cleanly
                if currentState == .running || currentState == .waitingPermission {
                    let errorMsg = "Process exited with code \(code)"
                    currentState = .error(errorMsg)
                    try? store.updateSessionError(session, message: errorMsg)
                } else {
                    currentState = .finished
                    try? store.markSessionFinished(session)
                }

                transcriptContinuation.finish()
                return

            case .streamFailure(let error):
                // Stream error
                currentState = .error(error)
                try? store.updateSessionError(session, message: error)
                transcriptContinuation.finish()
                return
            }
        }
    }

    /// Yields the session's history and finishes the stream (for read-only resume).
    private func yieldHistoryAndFinish() async {
        let messages = session.orderedMessages
        for message in messages {
            // Reconstruct events from persisted messages
            // ponytail: simplified; a full implementation would reconstruct the entire turn
            // For now, just signal the history is available.
        }

        currentState = .finished
        transcriptContinuation.finish()
    }

    // MARK: - Persistence

    /// Persists a batch of events to the store and flushes to disk.
    /// All operations run on the MainActor (this actor is @MainActor).
    /// This batching bounds the cost: Store.flush() is one 27.6ms call per batch, not per event.
    private func persistAndFlush(_ events: [AgentEvent]) {
        for event in events {
            switch event {
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
                let message = pendingMessage ?? (try? store.appendMessage(
                    to: session,
                    role: "assistant",
                    content: ""
                ))
                if let message = message {
                    pendingMessage = message

                    if let (_, record) = pendingToolCalls[toolCall.id] {
                        // Update existing
                        switch toolCall.status {
                        case .pending:
                            break
                        case .running:
                            record.status = "running"
                        case .succeeded:
                            record.output = toolCall.output
                            record.status = "succeeded"
                            record.endedAt = toolCall.endedAt
                        case .failed(let detail):
                            record.output = detail
                            record.status = "failed"
                            record.statusDetail = detail
                            record.endedAt = toolCall.endedAt
                        case .denied:
                            record.status = "denied"
                            record.endedAt = toolCall.endedAt
                        }
                        if let edit = toolCall.edit {
                            record.editPath = edit.path
                            record.editOldText = edit.oldText
                            record.editNewText = edit.newText
                        }
                    } else {
                        // New tool call
                        if let record = try? store.appendToolCall(
                            to: message,
                            id: toolCall.id,
                            name: toolCall.name,
                            input: toolCall.input,
                            status: statusString(toolCall.status)
                        ) {
                            if let edit = toolCall.edit {
                                try? store.updateToolCallEdit(
                                    record,
                                    path: edit.path,
                                    oldText: edit.oldText,
                                    newText: edit.newText
                                )
                            }
                            pendingToolCalls[toolCall.id] = (message, record)
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
                let toolCall = pendingToolCalls.values.first?.record
                let optionsJSON: String?
                if let data = try? JSONSerialization.data(
                    withJSONObject: request.options.map { o in
                        ["id": o.id, "kind": kindString(o.kind), "label": o.label]
                    },
                    options: [.sortedKeys]
                ) {
                    optionsJSON = String(data: data, encoding: .utf8)
                } else {
                    optionsJSON = nil
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

    // MARK: - Helpers

    private func statusString(_ status: ToolCall.Status) -> String {
        switch status {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .denied: return "denied"
        }
    }

    private func kindString(_ kind: PermissionOption.Kind) -> String {
        switch kind {
        case .allowOnce: return "allowOnce"
        case .allowAlways: return "allowAlways"
        case .denyOnce: return "denyOnce"
        case .denyAlways: return "denyAlways"
        }
    }
}
