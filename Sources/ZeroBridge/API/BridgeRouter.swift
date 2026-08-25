import Foundation

/// Method + path → one of the eight operations, with the pairing code checked first (FR-4).
///
/// The order matters and is not an implementation detail: **pairing before routing**. Checking the
/// path first would let an unpaired client learn which paths exist and which sessions do not, one
/// `404` at a time.
///
/// A value type holding two values, so the same router serves every connection without shared
/// mutable state to synchronise.
public struct BridgeRouter: BridgeRequestHandling {

    private let host: any BridgeHost
    private let pairingCode: PairingCode

    public init(host: any BridgeHost, pairingCode: PairingCode) {
        self.host = host
        self.pairingCode = pairingCode
    }

    // MARK: - HTTP

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        // FR-4: the header, constant-time, no hint about the real code, and nothing logged.
        guard pairingCode.matches(request.headers["x-zero-pair"]) else {
            return HTTPResponse.error(.unpaired)
        }
        do {
            var response = try await route(request)
            // A successful response leaves the connection open unless the client asked otherwise:
            // a phone polling `/api/health` should not pay for a new socket each time.
            if !request.wantsKeepAlive { response.closeConnection = true }
            return response
        } catch let error as BridgeError {
            return HTTPResponse.error(error)
        } catch {
            // Nothing from `error` reaches the wire: it could hold a path, a prompt, or a line of a
            // transcript. The client gets safe text and the contract's shape.
            return HTTPResponse.error(.internalFailure("The request could not be completed."))
        }
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = Path(request.path)
        let method = request.method.uppercased()
        // A path deeper than any route is not a route, and matching it on its first four
        // components would serve `/api/sessions/x/cancel/anything` as a cancel.
        guard path.components.count <= 4 else { throw BridgeError.notFound }

        switch (method, path.first, path.second, path.third, path.fourth) {
        case ("GET", "api", "health", nil, nil):
            return HTTPResponse.json(status: 200, await host.health())

        case ("GET", "api", "projects", nil, nil):
            return HTTPResponse.json(status: 200, await host.projects())

        case ("GET", "api", "sessions", nil, nil):
            return HTTPResponse.json(status: 200, await host.sessions())

        case ("POST", "api", "sessions", nil, nil):
            let body: CreateSessionRequest = try decode(request)
            return HTTPResponse.json(status: 201, try await host.createSession(body))

        case ("GET", "api", "sessions", .some(let id), nil):
            return HTTPResponse.json(status: 200, try await host.session(id: id))

        case ("POST", "api", "sessions", .some(let id), "messages"):
            let body: SendMessageRequest = try decode(request)
            try await host.sendMessage(body, in: id)
            return HTTPResponse.json(status: 202, OkBody())

        case ("POST", "api", "sessions", .some(let id), "cancel"):
            try await host.cancel(sessionId: id)
            return HTTPResponse.json(status: 202, OkBody())

        case ("POST", "api", "sessions", .some(let id), "permission"):
            let body: AnswerPermissionRequest = try decode(request)
            try await host.answerPermission(body, in: id)
            return HTTPResponse.json(status: 202, OkBody())

        default:
            throw BridgeError.notFound
        }
    }

    /// A body that will not decode is `400`, and the reason is the contract's fixed text rather
    /// than `DecodingError`'s: that description quotes the key it was looking at, and the body it
    /// came from is a prompt.
    private func decode<T: Decodable>(_ request: HTTPRequest) throws -> T {
        do {
            return try BridgeJSON.decode(T.self, from: request.body)
        } catch {
            throw BridgeError.badRequest("The request body is not the shape this endpoint expects.")
        }
    }

    // MARK: - WebSocket (FR-20, FR-21)

    public func subscribe(to request: HTTPRequest) async -> BridgeSubscription {
        // React Native cannot set WebSocket headers portably, so the code arrives as a query
        // parameter (FR-4). Wrong or missing closes *without upgrading*: a handshake that succeeded
        // and then closed has already said "this path exists".
        guard pairingCode.matches(request.query["pair"]) else {
            return .reject(HTTPResponse.error(.unpaired))
        }

        let path = Path(request.path)
        switch (path.first, path.second, path.third, path.fourth) {
        case ("api", "events", nil, nil):
            // No snapshot: the client fetches `GET /api/sessions` once and then follows the stream.
            return .accept(topic: .global, initial: [])

        case ("api", "sessions", .some(let id), "events"):
            do {
                let detail = try await host.session(id: id)
                // FR-20: the first frame is always the snapshot. Without it there is a race no
                // client can close — anything that happens between the `GET` and the socket opening
                // is lost, and the transcript is quietly wrong from then on.
                return .accept(
                    topic: .session(id),
                    initial: [.sessionSnapshot(sessionId: id, session: detail)]
                )
            } catch {
                // After the handshake, per CONTRACT.md: the client asked for a session that is not
                // there, which is a different thing from not being allowed to ask.
                return .closeAfterUpgrade(.policyViolation, "unknown session")
            }

        default:
            return .reject(HTTPResponse.error(.notFound))
        }
    }

    // MARK: - Paths

    /// The path, split once, so every route reads as a pattern instead of a series of prefix checks.
    private struct Path {
        let components: [String]

        init(_ path: String) {
            components = path.split(separator: "/").map(String.init)
        }

        /// The first four components, as optionals, so a route can be written as one tuple pattern
        /// with the session id bound in place. Swift will not bind a `let` inside an array pattern,
        /// and a chain of `if c.count == 4 && c[1] == "sessions"` is a route table nobody can read.
        var first: String? { components.count > 0 ? components[0] : nil }
        var second: String? { components.count > 1 ? components[1] : nil }
        var third: String? { components.count > 2 ? components[2] : nil }
        var fourth: String? { components.count > 3 ? components[3] : nil }
    }
}
