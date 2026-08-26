import Foundation

/// One option the provider offered, with the provider's own id.
///
/// Never an id Zero invented: Codex and ACP each use their own (`"accept"`, a wire-supplied
/// `optionId`), and answering with a made-up one hangs the agent.
public struct PermissionOptionDTO: Codable, Sendable, Equatable {
    public var id: String
    public var kind: PermissionOptionKind
    public var label: String

    public init(id: String, kind: PermissionOptionKind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}

/// A request waiting on a human (FR-17).
///
/// `detail` is complete and is never truncated by either side — truncating it is how someone
/// approves a command they did not read.
public struct PermissionRequestDTO: Codable, Sendable, Equatable {
    public var id: String
    public var toolName: String
    public var detail: String
    public var options: [PermissionOptionDTO]

    public init(id: String, toolName: String, detail: String, options: [PermissionOptionDTO]) {
        self.id = id
        self.toolName = toolName
        self.detail = detail
        self.options = options
    }
}
