import Foundation

/// The five wire statuses (FR-11).
///
/// `cancelled` is never produced by this version: cancelling a turn in Zero leaves the session
/// alive, so it reports `waiting`. It exists on the wire so a client that receives it from a later
/// version renders rather than crashes — which is why it is declared here and mapped from nothing.
public enum SessionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case waiting
    case completed
    case failed
    case cancelled
}

/// `SessionRuntime.Workspace` on the wire. Spelled out here rather than imported so the contract
/// owns its own names: renaming the Swift case must not silently rename a JSON value.
public enum WorkspaceDTO: String, Codable, Sendable, Equatable, CaseIterable {
    case currentCheckout
    case isolatedWorktree
}

/// Which side of a `Transcript.Entry` an `agent.output` event is amending (FR-23).
public enum AgentOutputKind: String, Codable, Sendable, Equatable {
    case assistant
    case thinking
}

/// `replace` carries the entry's full current text; `append` is a delta.
///
/// v0 always sends `replace` — see CONTRACT.md. `append` is in the contract so a later version can
/// use it without a wire change, and a client must handle both.
public enum AgentOutputMode: String, Codable, Sendable, Equatable {
    case append
    case replace
}

/// One `Transcript.Entry` case, named on the wire.
public enum EntryKind: String, Codable, Sendable, Equatable, CaseIterable {
    case userText
    case assistantText
    case thinking
    case tool
    case plan
    case notice
}

/// `ToolCall.Status` flattened: the `failed(String)` payload travels in `statusDetail`, so the
/// status itself stays a closed set of five strings a client can switch on.
public enum ToolStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case succeeded
    case failed
    case denied
}

/// `PermissionOption.Kind` on the wire.
public enum PermissionOptionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case allowOnce
    case allowAlways
    case denyOnce
    case denyAlways
}

/// `PlanItem.Status` on the wire.
public enum PlanItemStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case inProgress
    case completed
}

/// `PermissionMode` on the wire.
///
/// Spelled out rather than reusing `ZeroCore.PermissionMode` for the same reason as `WorkspaceDTO`:
/// the contract is frozen, and renaming a Swift case must not silently rename a JSON value. The
/// bridge adds no fourth mode (003-permission-modes).
public enum PermissionModeDTO: String, Codable, Sendable, Equatable, CaseIterable {
    case ask
    case auto
    case bypass
}
