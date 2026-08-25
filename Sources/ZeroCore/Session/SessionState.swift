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

    /// Whether the session still holds its workspace.
    ///
    /// A finished or failed session has let go of the checkout; anything else is still in there.
    public var isLive: Bool {
        switch self {
        case .idle, .running, .waitingPermission: return true
        case .finished, .error: return false
        }
    }

    /// Reconstructs a state from `Session.state`/`Session.errorMessage`, the way
    /// `PermissionMode.init(persisted:)` reconstructs a mode.
    ///
    /// Never `.running` or `.waitingPermission`: those describe a live process, and whatever
    /// process this session had is gone the moment the app that held its `Process` handle quits
    /// — there is nothing to persist "was reconnected" as. Restoring either verbatim would show a
    /// spinner, or an Allow/Deny control, that nothing will ever resolve. Both collapse to
    /// `.idle`, exactly what a freshly reopened session with history and nothing running looks
    /// like. An unrecognized string collapses to `.idle` too, rather than crashing on a row this
    /// type doesn't recognize.
    public init(persisted: String, errorMessage: String?) {
        switch persisted {
        case "error": self = .error(errorMessage ?? "")
        case "finished": self = .finished
        default: self = .idle
        }
    }
}
