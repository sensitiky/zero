import Foundation
import Observation
import SwiftUI
import ZeroBridge
import ZeroCore

/// `BridgeHost` over the window's own model and coordinator (FR-5).
///
/// Every read here is a projection of `AppModel`; every write is the same call the window makes.
/// There is no second way to start a session, send a message or answer a permission — which is why
/// the phone and the window cannot disagree about what a session is doing.
///
/// `@MainActor` because that is where `AppModel` and `SessionCoordinator` live. The protocol's
/// methods are `async`, so `ZeroBridge` calls them from its own tasks and the hop happens at the
/// boundary, carrying `Sendable` values across (FR-6).
@MainActor
final class BridgeHostAdapter: BridgeHost {

    private let model: AppModel
    private let coordinator: SessionCoordinator
    private let hub: EventHub

    /// What has been published about each session, so only changes go on the wire (E3).
    private var published: [UUID: PublishedState] = [:]

    init(model: AppModel, coordinator: SessionCoordinator, hub: EventHub) {
        self.model = model
        self.coordinator = coordinator
        self.hub = hub
    }

    // MARK: - Reads

    func health() async -> HealthDTO {
        HealthDTO(version: Self.version, sessionCount: model.sessions.count)
    }

    func projects() async -> [ProjectDTO] {
        model.projects.map { ProjectDTO(id: $0.id.path, name: $0.name) }
    }

    func sessions() async -> [SessionSummaryDTO] {
        model.sessions.map(summary(of:))
    }

    func session(id: String) async throws -> SessionDetailDTO {
        try detail(of: snapshot(id))
    }

    // MARK: - Writes

    func createSession(_ request: CreateSessionRequest) async throws -> SessionDetailDTO {
        let project = try resolveProject(request.project)
        let providerID = request.provider ?? model.draftProvider
        guard let descriptor = coordinator.descriptor(for: providerID) else {
            throw BridgeError.badRequest("No provider called \(providerID) is available in Zero.")
        }

        let before = Set(model.sessions.map(\.id))
        coordinator.lastError = nil
        await coordinator.startSession(
            repository: project.id,
            provider: descriptor,
            model: request.model ?? model.draftModel,
            prompt: request.prompt,
            // The window's remembered choice, for the same reason provider and model are (FR-14):
            // the phone has no place to choose one, and inventing a different default here would
            // make "start from the phone" a different feature from "start at the desk".
            workspace: model.draftWorkspace,
            permissionMode: request.permissionMode.map(Projection.permissionMode) ?? .ask
        )

        guard let created = model.sessions.first(where: { !before.contains($0.id) }) else {
            // FR-19: the coordinator's own words, so the phone shows what the window would have.
            throw BridgeError.conflict(
                coordinator.lastError ?? "Zero could not start that session."
            )
        }
        return detail(of: created)
    }

    func sendMessage(_ request: SendMessageRequest, in sessionId: String) async throws {
        let session = try snapshot(sessionId)
        coordinator.lastError = nil
        await coordinator.send(request.text, to: session.id)
        if let error = coordinator.lastError { throw BridgeError.conflict(error) }
    }

    func cancel(sessionId: String) async throws {
        let session = try snapshot(sessionId)
        coordinator.lastError = nil
        await coordinator.cancelTurn(session.id)
        if let error = coordinator.lastError { throw BridgeError.conflict(error) }
    }

    func answerPermission(_ request: AnswerPermissionRequest, in sessionId: String) async throws {
        let session = try snapshot(sessionId)
        guard let pending = session.pendingPermission else { throw BridgeError.stalePermission }
        // FR-17: answering a request that already resolved must not resolve the next one.
        guard pending.id == request.requestId else { throw BridgeError.stalePermission }
        guard let option = pending.options.first(where: { $0.id == request.optionId }) else {
            // Never an id Zero invented: the options are the provider's own, and one that is not on
            // the request would hang the agent.
            throw BridgeError.badRequest("That option is not one this request offered.")
        }
        // FR-18: this travels as `PermissionOrigin.userAction`, unchanged. A human answered it; the
        // only difference is which screen they were looking at.
        coordinator.answerPermission(sessionID: session.id, option: option)
    }

    // MARK: - Publishing (FR-22, FR-24, E3)

    /// One publication from the coordinator, as the frames a client gets.
    ///
    /// Called on the main actor, in the order things happened, straight after the model was updated
    /// — so the entry an event landed on is already in the transcript and can simply be read out
    /// (which is why the transport layer holds no copy of `Transcript`'s assembly rules).
    func publish(_ sessionID: UUID, _ publication: SessionCoordinator.Publication) {
        guard let session = model.sessions.first(where: { $0.id == sessionID }) else { return }
        let id = sessionID.uuidString

        switch publication {
        case .created:
            hub.publish(.sessionCreated(sessionId: id, session: summary(of: session)))
            // The baseline, so the first real transition is a change and not a repeat.
            published[sessionID] = state(of: session)

        case .agent(let event):
            if let frame = Projection.bridgeEvent(
                for: event, sessionId: id, transcript: session.transcript
            ) {
                hub.publish(frame)
            }
            publishStateChange(of: session)

        case .userMessage:
            // How a `userText` entry reaches other clients: a message sent from the phone must
            // appear on the Mac and on any second phone, and it is not agent output.
            if let entry = session.transcript.entries.last {
                hub.publish(.entryAppended(sessionId: id, entry: Projection.entry(entry)))
            }
            publishStateChange(of: session)

        case .permissionResolved(let requestId):
            hub.publish(.permissionResolved(sessionId: id, requestId: requestId))
            publishStateChange(of: session)
        }
    }

    /// A `session.state` per delta would be most of the traffic and none of the information.
    private func publishStateChange(of session: AppModel.SessionSnapshot) {
        let current = state(of: session)
        let previous = published[session.id]
        published[session.id] = current
        guard let previous else {
            hub.publish(
                .sessionState(
                    sessionId: session.id.uuidString,
                    status: current.status,
                    awaitingUser: current.awaitingUser,
                    error: current.error
                )
            )
            return
        }
        hub.publish(
            Projection.stateEvents(
                sessionId: session.id.uuidString,
                from: previous,
                to: current
            )
        )
    }

    /// Forget what was published, so a fresh listener starts from a clean baseline rather than
    /// inheriting the last run's.
    func resetPublishedState() {
        published.removeAll()
    }

    // MARK: - Projection

    private func state(of session: AppModel.SessionSnapshot) -> PublishedState {
        PublishedState(
            status: Projection.status(of: session.state),
            awaitingUser: session.pendingPermission != nil,
            error: Projection.error(of: session.state),
            summary: session.summary
        )
    }

    private func summary(of session: AppModel.SessionSnapshot) -> SessionSummaryDTO {
        SessionSummaryDTO(
            id: session.id.uuidString,
            title: session.title,
            summary: session.summary,
            status: Projection.status(of: session.state),
            projectId: session.projectID.path,
            projectName: model.projects.first { $0.id == session.projectID }?.name
                ?? session.projectID.lastPathComponent,
            provider: session.provider,
            model: session.model,
            branch: session.branch,
            workspace: Projection.workspace(session.workspace),
            permissionMode: Projection.permissionMode(session.permissionMode),
            // The one thing the client's accent is allowed to mark.
            awaitingUser: session.pendingPermission != nil,
            error: Projection.error(of: session.state)
        )
    }

    private func detail(of session: AppModel.SessionSnapshot) -> SessionDetailDTO {
        SessionDetailDTO(
            session: summary(of: session),
            entries: session.transcript.entries.map(Projection.entry),
            usage: Projection.usage(session.usage),
            pendingPermission: session.pendingPermission.map(Projection.permissionRequest)
        )
    }

    /// The snapshot for a wire id, or the contract's `404`.
    private func snapshot(_ id: String) throws -> AppModel.SessionSnapshot {
        guard let uuid = UUID(uuidString: id),
              let session = model.sessions.first(where: { $0.id == uuid }) else {
            throw BridgeError.sessionNotFound
        }
        return session
    }

    /// FR-14: by `id` (the checkout path) first, then by name.
    ///
    /// An unknown one is `422` **listing the open projects**, because the phone cannot show a folder
    /// picker and an error it cannot act on is an error it can only give up on.
    private func resolveProject(_ identifier: String) throws -> AppModel.Project {
        if let byPath = model.projects.first(where: { $0.id.path == identifier }) { return byPath }
        if let byName = model.projects.first(where: { $0.name == identifier }) { return byName }
        throw BridgeError.unknownProject(
            model.projects.map { ProjectDTO(id: $0.id.path, name: $0.name) }
        )
    }

    /// The app's own version, so `GET /api/health` reports what is running rather than a constant
    /// that goes stale.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
