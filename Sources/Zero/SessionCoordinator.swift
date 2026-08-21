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

    var availableProviders: [(descriptor: ProviderDescriptor, status: ProviderStatus)] {
        [ProviderDescriptor.claude, ProviderDescriptor.codex].map {
            ($0, registry.status(of: $0))
        }
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

    /// Asks for a repository. A folder picker rather than a text field: the path has to be a real
    /// git repository, and letting someone type one is letting them typo one.
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
        workspace: SessionRuntime.Workspace = .currentCheckout
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
                    workspace: workspace
                ),
                store: store,
                providerRegistry: registry
            )
            let id = runtime.id
            runtimes[id] = runtime
            try await broker.startSession(id: id.uuidString)

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
                    initialPrompt: prompt
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
                self.model.apply(event, to: id)
            }
        }
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
    func answerPermission(sessionID: UUID, option: PermissionOption) {
        guard let resolve = pendingResolvers.removeValue(forKey: sessionID) else { return }
        let allowed = option.kind == .allowOnce || option.kind == .allowAlways
        resolve(PermissionBroker.Resolution(decision: allowed ? .allow : .deny, origin: .userAction))
        model.resolvePermission(sessionID: sessionID)
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

    /// First line of the prompt, trimmed. A session needs a name in the sidebar and the prompt is the
    /// only thing that describes it at creation time.
    private static func title(from prompt: String) -> String {
        let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
