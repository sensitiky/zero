import Foundation
import Testing
import ZeroCore

@testable import ZeroBridge

/// The wire format, asserted as bytes.
///
/// These tests compare **literal JSON** against `docs/prds/005-mobile-remote-bridge/CONTRACT.md`
/// rather than round-tripping through `Codable`. A round-trip cannot catch a renamed key: both
/// sides of Swift agree on the new name and the test still passes, while every client written
/// against the contract breaks. The literal is the contract.
@Suite("Projection")
struct ProjectionTests {

    private func json(_ value: some Encodable) throws -> String {
        let data = try BridgeJSON.encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    /// Keys come out sorted (see `BridgeJSON`), so every expected literal below is in alphabetical
    /// key order — the same value always produces the same bytes.
    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    // MARK: - FR-11: status is total and explicit

    @Test("every SessionState maps to a wire status")
    func everyStateMaps() {
        #expect(Projection.status(of: .running) == .running)
        #expect(Projection.status(of: .waitingPermission) == .waiting)
        #expect(Projection.status(of: .idle) == .waiting)
        #expect(Projection.status(of: .finished) == .completed)
        #expect(Projection.status(of: .error("boom")) == .failed)
    }

    @Test("the two waiting kinds are told apart by pendingPermission, not by a second status")
    func waitingIsConflatedDeliberately() {
        // FR-11: `.idle` means "it needs an instruction" and `.waitingPermission` means "it needs a
        // decision". Both are `waiting` on the wire; the payload is the difference.
        #expect(Projection.status(of: .idle) == Projection.status(of: .waitingPermission))
    }

    @Test("cancelled is never produced")
    func cancelledIsNeverProduced() {
        // Cancelling a turn in Zero leaves the session alive, so there is no state to map from.
        // The name exists on the wire only so a client that receives it renders rather than crashes.
        let produced = [SessionState.idle, .running, .waitingPermission, .finished, .error("x")]
            .map(Projection.status(of:))
        #expect(!produced.contains(.cancelled))
    }

    @Test("only the error state carries an error")
    func onlyErrorCarriesAnError() {
        #expect(Projection.error(of: .error("provider exited with status 1"))
            == "provider exited with status 1")
        for state in [SessionState.idle, .running, .waitingPermission, .finished] {
            #expect(Projection.error(of: state) == nil)
        }
    }

    @Test("workspace and permission mode round-trip through their wire names")
    func enumsMap() {
        #expect(Projection.workspace(.currentCheckout) == .currentCheckout)
        #expect(Projection.workspace(.isolatedWorktree) == .isolatedWorktree)
        for mode in PermissionMode.allCases {
            #expect(Projection.permissionMode(Projection.permissionMode(mode)) == mode)
        }
    }

    // MARK: - FR-12: every entry case is typed on the wire

    @Test("every Transcript.Entry case projects with its own kind and its own UUID")
    func everyEntryCaseProjects() {
        let id = UUID()
        let cases: [(Transcript.Entry, EntryKind)] = [
            (.userText(id: id, text: "t"), .userText),
            (.assistantText(id: id, text: "t"), .assistantText),
            (.thinking(id: id, text: "t"), .thinking),
            (.notice(id: id, text: "t"), .notice),
            (.plan(id: id, items: []), .plan),
            (.tool(id: id, call: ToolCall(id: "c", name: "Read")), .tool),
        ]
        // Every case of the enum is here: six kinds on the wire for six cases in the domain.
        #expect(Set(cases.map(\.1)) == Set(EntryKind.allCases))
        for (entry, kind) in cases {
            let dto = Projection.entry(entry)
            #expect(dto.kind == kind)
            #expect(dto.id == id.uuidString)
        }
    }

    @Test("a userText entry carries text and nothing else")
    func userTextEntryJSON() throws {
        let id = try #require(UUID(uuidString: "8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0"))
        let dto = Projection.entry(.userText(id: id, text: "Investigate the Auth0 issue."))
        #expect(try json(dto) == #"""
            {"id":"8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0","kind":"userText","text":"Investigate the Auth0 issue."}
            """#)
    }

    @Test("a plan entry carries its items")
    func planEntryJSON() throws {
        let id = try #require(UUID(uuidString: "8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0"))
        let dto = Projection.entry(
            .plan(id: id, items: [PlanItem(id: "1", title: "Read AuthGuard.ts", status: .pending)])
        )
        #expect(try json(dto) == #"""
            {"id":"8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0","items":[{"id":"1","status":"pending","title":"Read AuthGuard.ts"}],"kind":"plan"}
            """#)
    }

    // MARK: - FR-13: the whole tool call

    @Test("a tool call carries name, status, input, output, timings and the edit")
    func toolCallJSON() throws {
        let call = ToolCall(
            id: "toolu_01ABC",
            name: "Read",
            input: #"{"file_path":"src/auth/AuthGuard.ts"}"#,
            output: "…",
            status: .pending,
            edit: FileEdit(path: "src/auth/AuthGuard.ts", oldText: "old", newText: "new"),
            startedAt: try date("2026-08-24T20:31:04Z")
        )
        #expect(try json(Projection.toolCall(call)) == #"""
            {"edit":{"newText":"new","oldText":"old","path":"src/auth/AuthGuard.ts"},"endedAt":null,"id":"toolu_01ABC","input":"{\"file_path\":\"src/auth/AuthGuard.ts\"}","name":"Read","output":"…","startedAt":"2026-08-24T20:31:04Z","status":"pending","statusDetail":null}
            """#)
    }

    @Test("every tool status has a wire name, and failed puts its reason in statusDetail")
    func toolStatuses() {
        let mapped: [(ToolCall.Status, ToolStatus, String?)] = [
            (.pending, .pending, nil),
            (.running, .running, nil),
            (.succeeded, .succeeded, nil),
            (.failed("exit 1"), .failed, "exit 1"),
            (.denied, .denied, nil),
        ]
        #expect(Set(mapped.map(\.1)) == Set(ToolStatus.allCases))
        for (status, expected, detail) in mapped {
            #expect(Projection.toolStatus(status) == expected)
            #expect(Projection.toolStatusDetail(status) == detail)
        }
    }

    @Test("edit is null unless the call edited a file")
    func editIsNullWithoutOne() throws {
        let dto = Projection.toolCall(ToolCall(id: "t", name: "Bash", status: .running))
        #expect(try json(dto).contains(#""edit":null"#))
    }

    @Test("input and output are sent whole, not truncated")
    func inputAndOutputAreNotTruncated() {
        let long = String(repeating: "x", count: 50_000)
        let dto = Projection.toolCall(
            ToolCall(id: "t", name: "Bash", input: long, output: long, status: .succeeded)
        )
        #expect(dto.input?.count == 50_000)
        #expect(dto.output?.count == 50_000)
    }

    // MARK: - Literal JSON for the rest of the contract

    @Test("ProjectDTO")
    func projectJSON() throws {
        let dto = ProjectDTO(
            id: "/Users/mariocorrea/Documents/Projects/millon-core",
            name: "millon-core"
        )
        #expect(try json(dto) == #"""
            {"id":"/Users/mariocorrea/Documents/Projects/millon-core","name":"millon-core"}
            """#)
    }

    static let summary = SessionSummaryDTO(
        id: "8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0",
        title: "Fix authentication bug",
        summary: "Looking at the JWT validation flow in AuthGuard.ts",
        status: .running,
        projectId: "/Users/mariocorrea/Documents/Projects/millon-core",
        projectName: "millon-core",
        provider: "Claude Code",
        model: "claude-opus-5",
        branch: "zero/fix-authentication-bug",
        workspace: .currentCheckout,
        permissionMode: .ask,
        awaitingUser: false,
        error: nil
    )

    @Test("SessionSummary, field by field")
    func summaryJSON() throws {
        #expect(try json(Self.summary) == #"""
            {"awaitingUser":false,"branch":"zero/fix-authentication-bug","error":null,"id":"8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0","model":"claude-opus-5","permissionMode":"ask","projectId":"/Users/mariocorrea/Documents/Projects/millon-core","projectName":"millon-core","provider":"Claude Code","status":"running","summary":"Looking at the JWT validation flow in AuthGuard.ts","title":"Fix authentication bug","workspace":"currentCheckout"}
            """#)
    }

    @Test("SessionDetail is the summary plus entries, usage and pendingPermission — flat")
    func detailJSON() throws {
        let detail = SessionDetailDTO(
            session: Self.summary,
            entries: [],
            usage: UsageDTO(),
            pendingPermission: nil
        )
        let text = try json(detail)
        // Flat, not nested: a client reading a list row and a detail row wants the same key at the
        // same depth in both.
        #expect(text.contains(#""title":"Fix authentication bug""#))
        #expect(text.contains(#""entries":[]"#))
        #expect(text.contains(#""pendingPermission":null"#))
        #expect(!text.contains(#""session":"#))
    }

    @Test("PermissionRequest carries the provider's own option ids")
    func permissionRequestJSON() throws {
        let request = PermissionRequest(
            id: "req_7f2",
            toolName: "Bash",
            detail: "curl -s https://api.example.com/v1/token",
            options: [
                PermissionOption(id: "allow", kind: .allowOnce, label: "Allow once"),
                PermissionOption(id: "always", kind: .allowAlways, label: "Allow always"),
                PermissionOption(id: "deny", kind: .denyOnce, label: "Deny"),
            ]
        )
        #expect(try json(Projection.permissionRequest(request)) == #"""
            {"detail":"curl -s https://api.example.com/v1/token","id":"req_7f2","options":[{"id":"allow","kind":"allowOnce","label":"Allow once"},{"id":"always","kind":"allowAlways","label":"Allow always"},{"id":"deny","kind":"denyOnce","label":"Deny"}],"toolName":"Bash"}
            """#)
    }

    @Test("every permission option kind has a wire name")
    func everyOptionKindMaps() {
        let kinds: [PermissionOption.Kind] = [.allowOnce, .allowAlways, .denyOnce, .denyAlways]
        #expect(Set(kinds.map(Projection.permissionOptionKind)) == Set(PermissionOptionKind.allCases))
    }

    @Test("Usage writes every field, and a null is written rather than omitted")
    func usageJSON() throws {
        let usage = Usage(
            model: "claude-opus-5",
            inputTokens: 41_233,
            outputTokens: 1_180,
            cacheReadTokens: 38_000,
            cacheWriteTokens: 2_100,
            contextWindowUsed: 41_233,
            contextWindowTotal: 200_000,
            thinkingTokens: nil,
            costUSD: 0.42
        )
        // `thinkingTokens: null` rather than absent: a client written against a key that is
        // sometimes missing and sometimes null has to handle two shapes for one fact.
        #expect(try json(Projection.usage(usage)) == #"""
            {"cacheReadTokens":38000,"cacheWriteTokens":2100,"contextWindowTotal":200000,"contextWindowUsed":41233,"costUSD":0.42,"inputTokens":41233,"model":"claude-opus-5","outputTokens":1180,"thinkingTokens":null}
            """#)
    }

    @Test("an unknown contextWindowTotal stays null so no client draws a fraction without one")
    func usageNullsAreExplicit() throws {
        #expect(try json(UsageDTO()) == #"""
            {"cacheReadTokens":null,"cacheWriteTokens":null,"contextWindowTotal":null,"contextWindowUsed":null,"costUSD":null,"inputTokens":null,"model":null,"outputTokens":null,"thinkingTokens":null}
            """#)
    }

    @Test("health")
    func healthJSON() throws {
        #expect(try json(HealthDTO(version: "0.1.0", sessionCount: 3)) == #"""
            {"app":"Zero","sessionCount":3,"version":"0.1.0"}
            """#)
    }

    // MARK: - Error bodies

    @Test("every error body is the contract's shape, with the contract's code and status")
    func errorBodies() throws {
        let expected: [(BridgeError, Int, String)] = [
            (.badRequest("no"), 400, "bad_request"),
            (.unpaired, 401, "unpaired"),
            (.sessionNotFound, 404, "session_not_found"),
            (.conflict("busy"), 409, "conflict"),
            (.stalePermission, 409, "stale_permission"),
            (.tooLarge, 413, "too_large"),
            (.unknownProject([]), 422, "unknown_project"),
            (.internalFailure("x"), 500, "internal"),
        ]
        for (error, status, code) in expected {
            #expect(error.status == status)
            #expect(error.body.error == code)
            #expect(!error.body.message.isEmpty)
        }
    }

    @Test("session_not_found is exactly the contract's example body")
    func notFoundBodyJSON() throws {
        #expect(try json(BridgeError.sessionNotFound.body) == #"""
            {"error":"session_not_found","message":"No session with that id is open in Zero."}
            """#)
    }

    @Test("unknown_project carries the valid projects and nothing else does")
    func unknownProjectBodyJSON() throws {
        let projects = [ProjectDTO(id: "/tmp/a", name: "a")]
        let text = try json(BridgeError.unknownProject(projects).body)
        #expect(text == #"""
            {"error":"unknown_project","message":"No project with that id or name is open in Zero.","projects":[{"id":"/tmp/a","name":"a"}]}
            """#)
        #expect(!(try json(BridgeError.badRequest("no").body).contains("projects")))
    }

    @Test("an unpaired body says nothing about the real code")
    func unpairedLeaksNothing() {
        let body = BridgeError.unpaired.body
        #expect(body.error == "unpaired")
        let hasDigit = body.message.contains { $0.isNumber }
        #expect(!hasDigit)
    }

    // MARK: - Request bodies

    @Test("the three request bodies decode the contract's fields")
    func requestBodiesDecode() throws {
        let create = try BridgeJSON.decode(
            CreateSessionRequest.self,
            from: Data(#"{"project":"millon-core","prompt":"go","permissionMode":"bypass"}"#.utf8)
        )
        #expect(create.project == "millon-core")
        #expect(create.prompt == "go")
        #expect(create.provider == nil)
        #expect(create.permissionMode == .bypass)

        let message = try BridgeJSON.decode(
            SendMessageRequest.self, from: Data(#"{"text":"hello"}"#.utf8)
        )
        #expect(message.text == "hello")

        let answer = try BridgeJSON.decode(
            AnswerPermissionRequest.self,
            from: Data(#"{"requestId":"req_7f2","optionId":"allow"}"#.utf8)
        )
        #expect(answer.requestId == "req_7f2")
        #expect(answer.optionId == "allow")
    }

    @Test("the body of every 202")
    func okBodyJSON() throws {
        #expect(try json(OkBody()) == #"{"ok":true}"#)
    }
}
