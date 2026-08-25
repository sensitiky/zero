import Foundation

/// Every non-2xx body, and it is the same shape every time.
///
/// `message` is safe text: never a transcript, never a request body, never the pairing code.
public struct ErrorBody: Codable, Sendable, Equatable {
    public var error: String
    public var message: String
    /// Only `unknown_project` carries this (FR-14). The phone cannot show a folder picker, so the
    /// error has to be actionable.
    public var projects: [ProjectDTO]?

    public init(error: String, message: String, projects: [ProjectDTO]? = nil) {
        self.error = error
        self.message = message
        self.projects = projects
    }

    enum CodingKeys: String, CodingKey { case error, message, projects }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(error, forKey: .error)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(projects, forKey: .projects)
    }
}

/// The closed set of failures the contract names, each with its status and its body.
///
/// A `throws` in a handler becomes exactly one of these, so no handler can invent a status or leak
/// a Swift error description onto the wire.
public enum BridgeError: Error, Sendable, Equatable {
    case badRequest(String)
    case unpaired
    case sessionNotFound
    /// A path (or a method on a path) this server does not serve.
    ///
    /// CONTRACT.md's table has no row for it — it only names the 404 a client gets for an unknown
    /// *session*. Reusing `session_not_found` for a wrong URL would tell a client its session had
    /// gone when what actually happened is that it asked for something this version does not have,
    /// so this is its own name.
    case notFound
    /// The coordinator refused, in its own words (FR-19), so the phone shows what the window would.
    case conflict(String)
    case stalePermission
    case tooLarge
    case unknownProject([ProjectDTO])
    case internalFailure(String)

    public var status: Int {
        switch self {
        case .badRequest: 400
        case .unpaired: 401
        case .sessionNotFound, .notFound: 404
        case .conflict, .stalePermission: 409
        case .tooLarge: 413
        case .unknownProject: 422
        case .internalFailure: 500
        }
    }

    public var body: ErrorBody {
        switch self {
        case .badRequest(let message):
            ErrorBody(error: "bad_request", message: message)
        case .unpaired:
            // No hint about the real code, and no detail about what was wrong with the one sent.
            ErrorBody(error: "unpaired", message: "Pairing code missing or incorrect.")
        case .sessionNotFound:
            ErrorBody(
                error: "session_not_found",
                message: "No session with that id is open in Zero."
            )
        case .notFound:
            ErrorBody(error: "not_found", message: "No such endpoint.")
        case .conflict(let message):
            ErrorBody(error: "conflict", message: message)
        case .stalePermission:
            ErrorBody(
                error: "stale_permission",
                message: "That permission request is not the one waiting for an answer."
            )
        case .tooLarge:
            ErrorBody(error: "too_large", message: "Request body over the 1 MiB limit.")
        case .unknownProject(let projects):
            ErrorBody(
                error: "unknown_project",
                message: "No project with that id or name is open in Zero.",
                projects: projects
            )
        case .internalFailure(let message):
            ErrorBody(error: "internal", message: message)
        }
    }
}
