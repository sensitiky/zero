import Foundation
import Synchronization
import Testing

@testable import ZeroBridge

/// FR-7 … FR-19 against a fake host: every endpoint, every error status, and the pairing check on
/// both transports.
@Suite("BridgeRouter")
struct BridgeRouterTests {

    // MARK: - Fixtures

    private static let code = "418205"

    private func summary(_ id: String, awaitingUser: Bool = false) -> SessionSummaryDTO {
        SessionSummaryDTO(
            id: id,
            title: "Fix authentication bug",
            summary: "Looking at the JWT validation flow in AuthGuard.ts",
            status: .running,
            projectId: "/Users/dev/millon-core",
            projectName: "millon-core",
            provider: "Claude Code",
            model: "claude-opus-5",
            branch: "zero/fix-authentication-bug",
            workspace: .currentCheckout,
            permissionMode: .ask,
            awaitingUser: awaitingUser
        )
    }

    private func detail(_ id: String) -> SessionDetailDTO {
        SessionDetailDTO(
            session: summary(id),
            entries: [EntryDTO(id: "e1", kind: .userText, text: "Investigate the Auth0 issue.")],
            usage: UsageDTO(model: "claude-opus-5", inputTokens: 41_233)
        )
    }

    private final class Calls: Sendable {
        private let entries = Mutex<[String]>([])
        func record(_ call: String) { entries.withLock { $0.append(call) } }
        var recorded: [String] { entries.withLock(\.self) }
    }

    private struct FakeHost: BridgeHost {
        var projectList: [ProjectDTO] = [
            ProjectDTO(id: "/Users/dev/millon-core", name: "millon-core"),
            ProjectDTO(id: "/Users/dev/zero", name: "zero"),
        ]
        var summaries: [SessionSummaryDTO] = []
        var details: [String: SessionDetailDTO] = [:]
        var createFailure: BridgeError?
        var writeFailure: BridgeError?
        var created: SessionDetailDTO?
        let calls: Calls

        func health() async -> HealthDTO {
            HealthDTO(version: "0.1.0", sessionCount: summaries.count)
        }

        func projects() async -> [ProjectDTO] { projectList }

        func sessions() async -> [SessionSummaryDTO] { summaries }

        func session(id: String) async throws -> SessionDetailDTO {
            guard let detail = details[id] else { throw BridgeError.sessionNotFound }
            return detail
        }

        func createSession(_ request: CreateSessionRequest) async throws -> SessionDetailDTO {
            calls.record("create(\(request.project))")
            if let createFailure { throw createFailure }
            guard let created else { throw BridgeError.internalFailure("no fixture") }
            return created
        }

        func sendMessage(_ request: SendMessageRequest, in sessionId: String) async throws {
            calls.record("send(\(sessionId),\(request.text))")
            if let writeFailure { throw writeFailure }
        }

        func cancel(sessionId: String) async throws {
            calls.record("cancel(\(sessionId))")
            if let writeFailure { throw writeFailure }
        }

        func answerPermission(
            _ request: AnswerPermissionRequest, in sessionId: String
        ) async throws {
            calls.record("permission(\(sessionId),\(request.requestId),\(request.optionId))")
            if let writeFailure { throw writeFailure }
        }
    }

    private func router(_ host: FakeHost) throws -> BridgeRouter {
        BridgeRouter(host: host, pairingCode: try #require(PairingCode(Self.code)))
    }

    private func request(
        _ method: String,
        _ target: String,
        pair: String? = code,
        body: (some Encodable)? = Optional<OkBody>.none,
        connection: String? = nil
    ) throws -> HTTPRequest {
        var headers = HTTPHeaders()
        if let pair { headers["X-Zero-Pair"] = pair }
        if let connection { headers["Connection"] = connection }
        let data = try body.map { try BridgeJSON.encode($0) } ?? Data()
        return HTTPRequest(method: method, target: target, headers: headers, body: data)
    }

    private func rawBody(_ method: String, _ target: String, _ raw: String) -> HTTPRequest {
        var headers = HTTPHeaders()
        headers["X-Zero-Pair"] = Self.code
        return HTTPRequest(method: method, target: target, headers: headers, body: Data(raw.utf8))
    }

    private func errorBody(_ response: HTTPResponse) throws -> ErrorBody {
        try BridgeJSON.decode(ErrorBody.self, from: response.body)
    }

    // MARK: - FR-4: pairing, on both transports

    @Test("a missing or wrong code is 401 with no hint about the real one")
    func unpairedHTTP() async throws {
        let router = try router(FakeHost(calls: Calls()))
        for pair in [nil, "", "418206", "41820", "4182050", " 418205"] {
            let response = await router.respond(to: try request("GET", "/api/health", pair: pair))
            #expect(response.status == 401)
            let body = try errorBody(response)
            #expect(body.error == "unpaired")
            #expect(!body.message.contains(Self.code))
            // Every error closes: a connection that failed to be understood is not one to keep
            // reading from.
            #expect(response.closeConnection)
        }
    }

    @Test("pairing is checked before routing, so an unpaired client learns nothing about paths")
    func pairingBeforeRouting() async throws {
        let router = try router(FakeHost(calls: Calls()))
        // Not 404: checking the path first would let an unpaired client map the server one status
        // code at a time.
        let unknownPath = await router.respond(to: try request("GET", "/nope", pair: nil))
        #expect(unknownPath.status == 401)
        let unknownSession = await router.respond(
            to: try request("GET", "/api/sessions/does-not-exist", pair: nil)
        )
        #expect(unknownSession.status == 401)
    }

    @Test("a WebSocket carries the code as a query parameter, and a wrong one never upgrades")
    func unpairedWebSocket() async throws {
        let router = try router(FakeHost(calls: Calls()))
        for target in ["/api/events", "/api/events?pair=418206", "/api/sessions/A/events"] {
            let decision = await router.subscribe(to: HTTPRequest(method: "GET", target: target))
            guard case .reject(let response) = decision else {
                Issue.record("\(target) was not rejected")
                return
            }
            #expect(response.status == 401)
            #expect(try errorBody(response).error == "unpaired")
        }
    }

    // MARK: - Read endpoints

    @Test("GET /api/health (FR-7)")
    func health() async throws {
        var host = FakeHost(calls: Calls())
        host.summaries = [summary("A"), summary("B"), summary("C")]
        let response = try await router(host).respond(to: try request("GET", "/api/health"))
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8)
            == #"{"app":"Zero","sessionCount":3,"version":"0.1.0"}"#)
    }

    @Test("GET /api/projects (FR-8)")
    func projects() async throws {
        let host = FakeHost(calls: Calls())
        let response = try await router(host).respond(to: try request("GET", "/api/projects"))
        #expect(response.status == 200)
        #expect(try BridgeJSON.decode([ProjectDTO].self, from: response.body) == host.projectList)
    }

    @Test("GET /api/sessions (FR-9)")
    func sessions() async throws {
        var host = FakeHost(calls: Calls())
        host.summaries = [summary("A"), summary("B")]
        let response = try await router(host).respond(to: try request("GET", "/api/sessions"))
        #expect(response.status == 200)
        #expect(try BridgeJSON.decode([SessionSummaryDTO].self, from: response.body).map(\.id)
            == ["A", "B"])
    }

    @Test("GET /api/sessions/:id, and 404 for an id the window does not have (FR-10)")
    func sessionDetail() async throws {
        var host = FakeHost(calls: Calls())
        host.details = ["A": detail("A")]
        let router = try router(host)

        let found = await router.respond(to: try request("GET", "/api/sessions/A"))
        #expect(found.status == 200)
        #expect(try BridgeJSON.decode(SessionDetailDTO.self, from: found.body) == detail("A"))

        let missing = await router.respond(to: try request("GET", "/api/sessions/B"))
        #expect(missing.status == 404)
        #expect(try errorBody(missing).error == "session_not_found")
    }

    @Test("a percent-encoded id is decoded before it reaches the host")
    func percentEncodedId() async throws {
        var host = FakeHost(calls: Calls())
        host.details = ["a b": detail("a b")]
        let response = try await router(host).respond(to: try request("GET", "/api/sessions/a%20b"))
        #expect(response.status == 200)
    }

    // MARK: - Write endpoints

    @Test("POST /api/sessions returns 201 with the created detail (FR-14)")
    func createSession() async throws {
        let calls = Calls()
        var host = FakeHost(calls: calls)
        host.created = detail("new")
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions",
                body: CreateSessionRequest(project: "millon-core", prompt: "Investigate Auth0")
            )
        )
        #expect(response.status == 201)
        #expect(try BridgeJSON.decode(SessionDetailDTO.self, from: response.body) == detail("new"))
        #expect(calls.recorded == ["create(millon-core)"])
    }

    @Test("an unknown project is 422 listing the ones that are open (FR-14)")
    func unknownProject() async throws {
        var host = FakeHost(calls: Calls())
        host.createFailure = .unknownProject(host.projectList)
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions",
                body: CreateSessionRequest(project: "nope", prompt: "x")
            )
        )
        #expect(response.status == 422)
        let body = try errorBody(response)
        #expect(body.error == "unknown_project")
        // The phone cannot show a folder picker, so the error has to be actionable.
        #expect(body.projects?.map(\.name) == ["millon-core", "zero"])
    }

    @Test("a refusal carries the coordinator's own words with 409 (FR-19)")
    func conflictCarriesTheCoordinatorsWords() async throws {
        var host = FakeHost(calls: Calls())
        host.createFailure = .conflict("That checkout is busy with another session.")
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions",
                body: CreateSessionRequest(project: "millon-core", prompt: "x")
            )
        )
        #expect(response.status == 409)
        let body = try errorBody(response)
        #expect(body.error == "conflict")
        // The phone shows what the window would have shown, not a generic failure.
        #expect(body.message == "That checkout is busy with another session.")
    }

    @Test("POST /api/sessions/:id/messages is 202 and reaches the host (FR-15)")
    func sendMessage() async throws {
        let calls = Calls()
        let host = FakeHost(calls: calls)
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions/A/messages", body: SendMessageRequest(text: "keep going")
            )
        )
        #expect(response.status == 202)
        #expect(String(data: response.body, encoding: .utf8) == #"{"ok":true}"#)
        #expect(calls.recorded == ["send(A,keep going)"])
    }

    @Test("POST /api/sessions/:id/cancel is 202 (FR-16)")
    func cancel() async throws {
        let calls = Calls()
        let host = FakeHost(calls: calls)
        let response = try await router(host).respond(to: try request("POST", "/api/sessions/A/cancel"))
        #expect(response.status == 202)
        #expect(calls.recorded == ["cancel(A)"])
    }

    @Test("POST /api/sessions/:id/permission is 202 with the provider's own ids (FR-17)")
    func answerPermission() async throws {
        let calls = Calls()
        let host = FakeHost(calls: calls)
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions/A/permission",
                body: AnswerPermissionRequest(requestId: "req_7f2", optionId: "allow")
            )
        )
        #expect(response.status == 202)
        // Never a hardcoded id, and never an option Zero invented: what the client sent is what the
        // host is asked to answer with.
        #expect(calls.recorded == ["permission(A,req_7f2,allow)"])
    }

    @Test("answering a request that already resolved is 409 stale_permission (FR-17)")
    func stalePermission() async throws {
        var host = FakeHost(calls: Calls())
        host.writeFailure = .stalePermission
        let response = try await router(host).respond(
            to: try request(
                "POST", "/api/sessions/A/permission",
                body: AnswerPermissionRequest(requestId: "req_old", optionId: "allow")
            )
        )
        #expect(response.status == 409)
        #expect(try errorBody(response).error == "stale_permission")
    }

    @Test("a write to a session that is gone is 404")
    func writeToMissingSession() async throws {
        var host = FakeHost(calls: Calls())
        host.writeFailure = .sessionNotFound
        for target in ["/api/sessions/A/messages", "/api/sessions/A/cancel"] {
            let response = try await router(host).respond(
                to: try request("POST", target, body: SendMessageRequest(text: "x"))
            )
            #expect(response.status == 404)
            #expect(try errorBody(response).error == "session_not_found")
        }
    }

    // MARK: - Malformed and unknown

    @Test("a body that is not the expected shape is 400, and says nothing about the body")
    func malformedBody() async throws {
        let router = try router(FakeHost(calls: Calls()))
        for raw in ["", "not json", "{}", #"{"text":5}"#] {
            let response = await router.respond(
                to: rawBody("POST", "/api/sessions/A/messages", raw)
            )
            #expect(response.status == 400)
            let body = try errorBody(response)
            #expect(body.error == "bad_request")
            // `DecodingError`'s description quotes the key it was looking at, and the body it came
            // from is a prompt.
            #expect(!body.message.contains(raw) || raw.isEmpty)
        }
    }

    @Test("an unknown path, and a known path with the wrong method, are 404")
    func unknownRoutes() async throws {
        let router = try router(FakeHost(calls: Calls()))
        let cases = [
            ("GET", "/"),
            ("GET", "/api"),
            ("GET", "/api/nope"),
            ("DELETE", "/api/sessions/A"),
            ("GET", "/api/sessions/A/cancel"),
            ("POST", "/api/sessions/A/cancel/now"),
            ("GET", "/api/sessions/A/messages"),
        ]
        for (method, target) in cases {
            let response = await router.respond(to: try request(method, target))
            #expect(response.status == 404, "\(method) \(target)")
            // Not `session_not_found`: telling a client its session is gone when the URL was wrong
            // is a lie it cannot debug.
            #expect(try errorBody(response).error == "not_found")
        }
    }

    @Test("Connection: close is honoured on a successful response")
    func connectionClose() async throws {
        var host = FakeHost(calls: Calls())
        host.summaries = []
        let router = try router(host)
        let keepAlive = await router.respond(to: try request("GET", "/api/sessions"))
        #expect(!keepAlive.closeConnection)
        let closing = await router.respond(
            to: try request("GET", "/api/sessions", connection: "close")
        )
        #expect(closing.closeConnection)
    }

    // MARK: - WebSocket routing (FR-20, FR-21)

    @Test("the session stream's first frame is always the snapshot (FR-20)")
    func snapshotFirst() async throws {
        var host = FakeHost(calls: Calls())
        host.details = ["A": detail("A")]
        let decision = try await router(host).subscribe(
            to: HTTPRequest(method: "GET", target: "/api/sessions/A/events?pair=\(Self.code)")
        )
        guard case .accept(let topic, let initial) = decision else {
            Issue.record("the subscription was refused")
            return
        }
        #expect(topic == .session("A"))
        #expect(initial.count == 1)
        #expect(initial.first == .sessionSnapshot(sessionId: "A", session: detail("A")))
    }

    @Test("the list stream has no snapshot (FR-21)")
    func listStreamHasNoSnapshot() async throws {
        let decision = try await router(FakeHost(calls: Calls())).subscribe(
            to: HTTPRequest(method: "GET", target: "/api/events?pair=\(Self.code)")
        )
        guard case .accept(let topic, let initial) = decision else {
            Issue.record("the subscription was refused")
            return
        }
        // The client fetches `GET /api/sessions` once and then follows the stream.
        #expect(topic == .global)
        #expect(initial.isEmpty)
    }

    @Test("an unknown session id closes with 1008 after the handshake")
    func unknownSessionStream() async throws {
        let decision = try await router(FakeHost(calls: Calls())).subscribe(
            to: HTTPRequest(method: "GET", target: "/api/sessions/nope/events?pair=\(Self.code)")
        )
        guard case .closeAfterUpgrade(let code, _) = decision else {
            Issue.record("an unknown session did not close after the handshake")
            return
        }
        #expect(code == .policyViolation)
    }

    @Test("an unknown WebSocket path is refused before the handshake")
    func unknownStreamPath() async throws {
        let decision = try await router(FakeHost(calls: Calls())).subscribe(
            to: HTTPRequest(method: "GET", target: "/api/nope?pair=\(Self.code)")
        )
        guard case .reject(let response) = decision else {
            Issue.record("an unknown stream path was not rejected")
            return
        }
        #expect(response.status == 404)
        #expect(try errorBody(response).error == "not_found")
    }
}
