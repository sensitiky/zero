import Foundation

/// Everything the bridge can ask the app to do, and the whole of it.
///
/// Eight operations, DTOs in and out. `ZeroBridge` does not import `Zero`, does not know about
/// `AppModel`, `SessionCoordinator` or AppKit, and holds no session state of its own (FR-5): every
/// read here is a projection of what the window already has, and every write is a call the window
/// would have made itself.
///
/// That is what makes the router testable against a fake and the app testable without a socket —
/// and it is what stops "the phone's way of starting a session" from ever becoming a second code
/// path with its own bugs.
public protocol BridgeHost: Sendable {

    /// FR-7. Validating the pairing code is the router's job; this only reports.
    func health() async -> HealthDTO

    /// FR-8 — the projects currently open in the window.
    func projects() async -> [ProjectDTO]

    /// FR-9 — one summary per session.
    func sessions() async -> [SessionSummaryDTO]

    /// FR-10 — the summary plus entries, usage and any pending permission.
    /// Throws `BridgeError.sessionNotFound` for an id the window does not have.
    func session(id: String) async throws -> SessionDetailDTO

    /// FR-14. Throws `.unknownProject` (listing the open ones) or `.conflict` in the coordinator's
    /// own words.
    func createSession(_ request: CreateSessionRequest) async throws -> SessionDetailDTO

    /// FR-15 — the user's message, which must appear on both screens.
    func sendMessage(_ request: SendMessageRequest, in sessionId: String) async throws

    /// FR-16 — the turn ends; the session stays alive and reports `waiting`.
    func cancel(sessionId: String) async throws

    /// FR-17/FR-18 — answered by a human, as `PermissionOrigin.userAction`. Throws
    /// `.stalePermission` when `requestId` is not the one waiting.
    func answerPermission(_ request: AnswerPermissionRequest, in sessionId: String) async throws
}
