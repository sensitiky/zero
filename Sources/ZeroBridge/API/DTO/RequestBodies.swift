import Foundation

/// `POST /api/sessions` (FR-14). `project` matches an open project by `id` (path) or by `name`;
/// `provider`/`model` default to what the window remembers; `permissionMode` defaults to `ask`.
public struct CreateSessionRequest: Codable, Sendable, Equatable {
    public var project: String
    public var prompt: String
    public var provider: String?
    public var model: String?
    public var permissionMode: PermissionModeDTO?

    public init(
        project: String,
        prompt: String,
        provider: String? = nil,
        model: String? = nil,
        permissionMode: PermissionModeDTO? = nil
    ) {
        self.project = project
        self.prompt = prompt
        self.provider = provider
        self.model = model
        self.permissionMode = permissionMode
    }
}

/// `POST /api/sessions/:id/messages` (FR-15).
public struct SendMessageRequest: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// `POST /api/sessions/:id/permission` (FR-17).
///
/// `requestId` is required and checked against the pending one: answering a request that already
/// resolved must not resolve the next one.
public struct AnswerPermissionRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var optionId: String

    public init(requestId: String, optionId: String) {
        self.requestId = requestId
        self.optionId = optionId
    }
}

/// The body of every `202`.
public struct OkBody: Codable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}
