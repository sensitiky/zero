import Foundation

/// A project open in the window. `id` is the checkout path — the identity `AppModel.Project`
/// already uses, so the bridge invents no second one.
public struct ProjectDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One line of the sessions list.
///
/// `awaitingUser` is true only when a permission request is pending — the one thing the client's
/// accent is allowed to mark.
public struct SessionSummaryDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var summary: String
    public var status: SessionStatus
    public var projectId: String
    public var projectName: String
    public var provider: String
    public var model: String
    public var branch: String
    public var workspace: WorkspaceDTO
    public var permissionMode: PermissionModeDTO
    public var awaitingUser: Bool
    public var error: String?

    public init(
        id: String,
        title: String,
        summary: String,
        status: SessionStatus,
        projectId: String,
        projectName: String,
        provider: String,
        model: String,
        branch: String,
        workspace: WorkspaceDTO,
        permissionMode: PermissionModeDTO,
        awaitingUser: Bool,
        error: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.projectId = projectId
        self.projectName = projectName
        self.provider = provider
        self.model = model
        self.branch = branch
        self.workspace = workspace
        self.permissionMode = permissionMode
        self.awaitingUser = awaitingUser
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, status, projectId, projectName, provider, model, branch
        case workspace, permissionMode, awaitingUser, error
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(status, forKey: .status)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(branch, forKey: .branch)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(awaitingUser, forKey: .awaitingUser)
        try container.encodeExplicit(error, forKey: .error)
    }
}

/// The summary plus the conversation. Encoded **flat**: CONTRACT.md says "`SessionSummary` plus",
/// not "a nested `summary` object", and a client reading a list row and a detail row wants the same
/// key at the same depth in both.
public struct SessionDetailDTO: Codable, Sendable, Equatable {
    public var session: SessionSummaryDTO
    public var entries: [EntryDTO]
    public var usage: UsageDTO
    public var pendingPermission: PermissionRequestDTO?

    public init(
        session: SessionSummaryDTO,
        entries: [EntryDTO],
        usage: UsageDTO,
        pendingPermission: PermissionRequestDTO? = nil
    ) {
        self.session = session
        self.entries = entries
        self.usage = usage
        self.pendingPermission = pendingPermission
    }

    enum CodingKeys: String, CodingKey { case entries, usage, pendingPermission }

    public init(from decoder: any Decoder) throws {
        session = try SessionSummaryDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([EntryDTO].self, forKey: .entries)
        usage = try container.decode(UsageDTO.self, forKey: .usage)
        pendingPermission = try container.decodeIfPresent(
            PermissionRequestDTO.self, forKey: .pendingPermission
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try session.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(usage, forKey: .usage)
        try container.encodeExplicit(pendingPermission, forKey: .pendingPermission)
    }
}

/// `GET /api/health` (FR-7). It validates the pairing code, so "Connect" on the client is a real
/// check rather than a reachability guess.
public struct HealthDTO: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var sessionCount: Int

    public init(app: String = "Zero", version: String, sessionCount: Int) {
        self.app = app
        self.version = version
        self.sessionCount = sessionCount
    }
}
