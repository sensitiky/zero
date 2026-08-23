import AppKit
import Foundation
import Observation
import SwiftUI
import ZeroCore

/// Bridges the runtime actors to the observable model.
///
/// The split matters: `SessionRuntime` actors read pipes and decode JSON off the main actor, and
/// this type only receives already-normalized `AgentEvent` values and applies them to `AppModel`.
/// Nothing here parses, spawns or touches git — if it did, the NFR forbidding that work on the main
/// actor would be unmeetable no matter how the runtime is written.
@MainActor
@Observable
final class SessionCoordinator {
    private let model: AppModel
    private let registry = ProviderRegistry()
    private var store: Store?
    private var broker: PermissionBroker?
    private var runtimes: [UUID: SessionRuntime] = [:]
    private var pumps: [UUID: Task<Void, Never>] = [:]
    /// Permission requests waiting on the user, keyed by session, so an answer can be routed back to
    /// the runtime that is blocked on it.
    private var pendingResolvers: [UUID: (PermissionBroker.Resolution) -> Void] = [:]

    var lastError: String?

    /// Which checkout each in-place session holds, so a second one cannot join it.
    private var occupiedCheckouts: [URL: UUID] = [:]

    init(model: AppModel) {
        self.model = model
    }

    /// Cached: `ProviderRegistry.status(of:)` spawns a subprocess to read `--version`. Every reader
    /// of this — `ComposeView`'s provider picker and its unavailable-reason text, both re-evaluated
    /// on every keystroke since they sit under `ComposeView`'s own local `@State` for the task
    /// field — was doing that spawn, per provider, on every keystroke. A provider's installed state
    /// does not change within a running session in practice, so computing this once is the right
    /// trade, not just a faster one.
    private var cachedProviders: [(descriptor: ProviderDescriptor, status: ProviderStatus)]?

    var availableProviders: [(descriptor: ProviderDescriptor, status: ProviderStatus)] {
        if let cachedProviders { return cachedProviders }
        let computed = [ProviderDescriptor.claude, ProviderDescriptor.codex].map {
            ($0, registry.status(of: $0))
        }
        cachedProviders = computed
        return computed
    }

    func descriptor(for id: String) -> ProviderDescriptor? {
        availableProviders.first { $0.descriptor.id == id }?.descriptor
    }

    func isAvailable(_ id: String) -> Bool {
        guard let entry = availableProviders.first(where: { $0.descriptor.id == id }) else { return false }
        if case .available = entry.status { return true }
        return false
    }

    /// Why a provider cannot be used, in the words the registry gave us.
    ///
    /// An unusable provider stays visible with its reason rather than being hidden: hiding it turns
    /// a fixable setup problem into a mystery.
    func unavailableReason(for id: String) -> String? {
        guard let entry = availableProviders.first(where: { $0.descriptor.id == id }) else { return nil }
        switch entry.status {
        case .available:
            return nil
        case .notInstalled(let reason), .notAuthenticated(let reason), .resolutionFailed(let reason):
            return reason
        case .versionTooOld(let installed, let minimum, _):
            return "Installed \(installed); Zero needs \(minimum) or newer."
        }
    }

    // MARK: - Starting a session

    /// Asks for a folder to work in. A picker rather than a text field: letting someone type a
    /// path is letting them typo one. It need not be a git repository — an in-place session only
    /// reads git to label itself (see `SessionRuntime.create`); a new worktree is what needs one.
    func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func startSession(
        repository: URL,
        provider: ProviderDescriptor,
        model modelName: String,
        prompt: String,
        workspace: SessionRuntime.Workspace = .currentCheckout,
        permissionMode: PermissionMode = .ask
    ) async {
        if workspace == .currentCheckout, let holder = occupiedCheckouts[repository],
           model.sessions.first(where: { $0.id == holder })?.state.isLive == true {
            lastError = SessionRuntime.CreationError.checkoutBusy(path: repository.path).description
            return
        }
        do {
            let store = try currentStore()
            let broker = try await currentBroker()
            let runtime = try await SessionRuntime.create(
                with: SessionRuntime.CreationConfig(
                    repository: repository,
                    provider: provider,
                    model: modelName,
                    prompt: prompt,
                    workspace: workspace,
                    permissionMode: permissionMode
                ),
                store: store,
                providerRegistry: registry,
                // Without this the CLI launches with no PreToolUse hook installed, and a tool call
                // gets no one to ask: it either falls back to asking in plain chat text, or is denied
                // outright depending on the CLI's own default. Either way the native prompt this app
                // exists to show never appears. That was a real bug, not a config gap. `.bypass`
                // omits it on purpose (see `SessionRuntime.permissionArguments`) rather than by this
                // check ever returning nil for Claude Code.
                permissionSetup: provider.id == ProviderDescriptor.claude.id
                    ? .init(broker: broker, helperPath: Self.helperPath())
                    : nil
            )
            let id = runtime.id
            runtimes[id] = runtime

            // Branch comes from the store rather than the runtime: it is already persisted there,
            // and asking the actor for it would be an actor hop for a value we own.
            let branch = (try? store.fetchSession(id: id))?.branch ?? "—"

            model.sessions.append(
                AppModel.SessionSnapshot(
                    id: id,
                    projectID: repository,
                    title: Self.title(from: prompt),
                    provider: provider.displayName,
                    model: modelName,
                    branch: branch,
                    workspace: workspace,
                    state: .running,
                    initialPrompt: prompt,
                    permissionMode: permissionMode
                )
            )
            // The opening request belongs in the transcript too: it is the first thing said, and a
            // conversation that starts with the reply reads as if the question was lost.
            model.appendUserMessage(prompt, to: id)
            if workspace == .currentCheckout { occupiedCheckouts[repository] = id }
            model.selection = .session(id)
            pump(runtime, id: id)
        } catch let error as SessionRuntime.CreationError {
            lastError = error.description
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Feeds one runtime's transcript into the model.
    ///
    /// One task per session, so a slow or stuck session cannot hold up another's rendering — which
    /// is the whole point of running several at once.
    private func pump(_ runtime: SessionRuntime, id: UUID) {
        pumps[id] = Task { [weak self] in
            for await event in runtime.transcript {
                guard let self else { return }
                if case .permissionRequested(let request) = event,
                   let mode = self.model.sessions.first(where: { $0.id == id })?.permissionMode,
                   mode != .ask {
                    // Codex/ACP only: Claude Code's requests never reach this stream (see
                    // `ClaudeCodeEncoder.encodePermissionResponse`) — they go through
                    // `PermissionBroker` and its own matcher-based Ask/Auto split instead. Here,
                    // `.auto` and `.bypass` are identical: neither protocol exposes a native
                    // "provider decides for itself" the way Claude Code's `--permission-mode auto`
                    // does (see the PRD's Open Questions), so Zero resolves locally rather than
                    // showing the control — never as a decision the model made (FR-25).
                    await self.autoResolvePermission(request, mode: mode, runtime: runtime)
                    continue
                }
                self.model.apply(event, to: id)
            }
        }
    }

    /// Picks the allow option from the request itself — never a hardcoded id, since Codex and ACP
    /// each use their own provider-native option ids (`"accept"`, a wire-supplied `optionId`, …).
    /// Falls back to denying if no allow option is offered at all: failing closed here matches
    /// `PermissionBroker`'s own rule for the same situation.
    private func autoResolvePermission(
        _ request: PermissionRequest,
        mode: PermissionMode,
        runtime: SessionRuntime
    ) async {
        let chosen = request.options.first(where: { $0.kind == .allowOnce })
            ?? request.options.first(where: { $0.kind == .denyOnce })
        guard let chosen else { return }
        try? await runtime.resolvePermission(
            requestID: request.id,
            optionID: chosen.id,
            origin: .rule("permission-mode:\(mode.rawValue)")
        )
    }

    // MARK: - Turns

    func send(_ text: String, to id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        // Shown before the write is attempted, so the message never appears to vanish. If the send
        // fails the error says so, which is better than a message that was silently never recorded.
        model.appendUserMessage(text, to: id)
        do {
            try await runtime.send(text)
        } catch {
            lastError = "Could not send: \(String(describing: error))"
        }
    }

    func cancelTurn(_ id: UUID) async {
        await runtimes[id]?.cancelTurn()
    }

    // MARK: - Permissions

    /// Resolves the request the user just answered.
    ///
    /// The decision travels with `PermissionOrigin.userAction`, which is the only origin this path
    /// can produce: nothing decoded from the agent or from a tool result can reach here.
    ///
    /// Two paths, chosen by which one is waiting: a Claude Code request is parked in
    /// `pendingResolvers` by `awaitUserDecision` and answered through the hook broker; a Codex/ACP
    /// request has no such entry because it never went through the broker, so the answer is
    /// encoded and sent back in-band instead, via `SessionRuntime.resolvePermission`.
    func answerPermission(sessionID: UUID, option: PermissionOption) {
        let allowed = option.kind == .allowOnce || option.kind == .allowAlways
        if let resolve = pendingResolvers.removeValue(forKey: sessionID) {
            resolve(PermissionBroker.Resolution(decision: allowed ? .allow : .deny, origin: .userAction))
        } else if let runtime = runtimes[sessionID],
                  let request = model.sessions.first(where: { $0.id == sessionID })?.pendingPermission {
            Task {
                try? await runtime.resolvePermission(
                    requestID: request.id,
                    optionID: option.id,
                    origin: .userAction
                )
            }
        }
        model.resolvePermission(sessionID: sessionID)
    }

    // MARK: - Permission mode

    /// Changes a session's permission mode.
    ///
    /// No hot-swap: `--settings` and `--permission-mode` are launch-time arguments for Claude Code,
    /// and Codex/ACP have no live-reconfiguration channel either, so a live session relaunches
    /// through the same `SessionRuntime.resume` that already handles reopening a session after the
    /// app restarts — degrading to read-only exactly where FR-7 of `001-agent-chat-core` already
    /// says it must (no `providerSessionId`, or a provider without a verified resume flag).
    func setPermissionMode(_ mode: PermissionMode, for sessionID: UUID) async {
        guard let store = try? currentStore(),
              let session = try? store.fetchSession(id: sessionID) else { return }
        do {
            try store.updatePermissionMode(session, mode: mode)
        } catch {
            lastError = "Could not save permission mode: \(String(describing: error))"
            return
        }
        model.setPermissionMode(mode, for: sessionID)

        // Nothing running to relaunch — a session that has not started yet, or already ended, just
        // gets the new mode for whenever it (re)starts.
        guard let runtime = runtimes[sessionID],
              model.sessions.first(where: { $0.id == sessionID })?.state.isLive == true else { return }

        pumps[sessionID]?.cancel()
        do {
            let broker = try await currentBroker()
            await broker.stopSession(id: sessionID.uuidString)
            await runtime.terminate()
            runtimes.removeValue(forKey: sessionID)

            let newRuntime = try await SessionRuntime.resume(
                sessionID: sessionID,
                store: store,
                providerRegistry: registry,
                permissionMode: mode,
                permissionSetup: session.provider == ProviderDescriptor.claude.id
                    ? .init(broker: broker, helperPath: Self.helperPath())
                    : nil
            )
            runtimes[sessionID] = newRuntime
            if await newRuntime.state == .finished {
                model.appendNotice(
                    "Switched to \(mode.label), but this provider has no verified resume — the "
                        + "session ended here; its history stays readable.",
                    to: sessionID
                )
            }
            pump(newRuntime, id: sessionID)
        } catch {
            lastError = "Could not relaunch with the new permission mode: \(String(describing: error))"
        }
    }

    // MARK: - Lazily built dependencies

    private func currentStore() throws -> Store {
        if let store { return store }
        let created = try Store()
        store = created
        return created
    }

    private func currentBroker() async throws -> PermissionBroker {
        if let broker { return broker }
        let created = PermissionBroker(
            socketsDirectory: PermissionBroker.defaultSocketsDirectory()
        ) { [weak self] request in
            // Nothing to classify here anymore: the hook's matcher now only intercepts network
            // fetches, and every request that reaches this closure is one we already decided
            // always needs a human. See `HookSettings.defaultMatcher` and `ProviderDescriptor.claude`.
            await self?.awaitUserDecision(for: request)
                ?? PermissionBroker.Resolution(decision: .deny, origin: .userAction)
        }
        broker = created
        return created
    }

    /// Suspends the runtime's permission request until the user answers in the UI.
    ///
    /// If the window is gone or the session is unknown, this returns a deny: the broker's timeout is
    /// the backstop, but a request that can never be shown should not wait for it.
    private func awaitUserDecision(for request: PermissionRequest) async -> PermissionBroker.Resolution {
        guard let sessionID = model.selectedSessionID ?? model.sessions.first?.id else {
            return PermissionBroker.Resolution(decision: .deny, origin: .userAction)
        }
        model.apply(.permissionRequested(request), to: sessionID)
        return await withCheckedContinuation { continuation in
            var resumed = false
            pendingResolvers[sessionID] = { resolution in
                // Guarded because a double answer — a click racing a keyboard shortcut — would
                // otherwise resume the continuation twice and crash the app.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: resolution)
            }
        }
    }

    /// The permission hook helper, expected alongside this executable inside the app bundle.
    private static func helperPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/zero-permission-hook")
            .path
    }

    /// First line of the prompt, trimmed. A session needs a name in the sidebar and the prompt is the
    /// only thing that describes it at creation time.
    private static func title(from prompt: String) -> String {
        let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
