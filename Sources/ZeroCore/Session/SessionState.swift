import Foundation

/// The state of a session at a point in time.
///
/// Transitions are total and deterministic: every `AgentEvent` and process lifecycle event drives
/// a well-defined state machine. No state mutation happens outside this type — it is the source of truth.
public enum SessionState: Sendable, Equatable {
    /// Session created, awaiting the first prompt or permission.
    case idle

    /// Agent is running: processing messages and generating output.
    case running

    /// Agent paused, waiting for the user to resolve a permission request.
    case waitingPermission

    /// Session ended with an error. History is preserved; the worktree remains.
    case error(String)

    /// Session ended cleanly. History is preserved; the worktree remains for inspection.
    case finished
}
