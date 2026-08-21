import Foundation
import ZeroCore

/// Seeds `AppModel` with a full mock conversation, for looking at the UI without a real agent.
///
/// Built by feeding real `AgentEvent` values through `Transcript.apply`, the same path a live
/// session drives — so this exercises the actual assembly code (turn boundaries, tool call
/// upserts, usage merging) rather than hand-building a `Transcript` that could drift from what
/// production ever produces.
///
/// Only reached when `ZERO_PREVIEW=1` is set, which the preview bundle's `Info.plist` sets via
/// `LSEnvironment` — a normal build never sees this.
@MainActor
enum PreviewData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ZERO_PREVIEW"] == "1"
    }

    static func seed(into model: AppModel) {
        let repo = URL(fileURLWithPath: "/Users/mariocorrea/Documents/Projects/millon-core")
        let apiRepo = URL(fileURLWithPath: "/Users/mariocorrea/Documents/Projects/millon-api")
        model.projects = [AppModel.Project(url: repo), AppModel.Project(url: apiRepo)]

        let busy = makeBusySession(in: repo)
        // Titled from a prompt that starts with a markdown heading, on purpose: demonstrates that
        // the sidebar strips "# " rather than showing it literally — the bug this session type
        // exists to catch, per the process rule that every UI fix shows up here too.
        let idle = makeIdleSession(in: repo, title: "# Fix flaky checkout test", branch: "zero/flaky-checkout-9f2")
        let waiting = makeWaitingSession(in: apiRepo)
        let finished = makeFinishedSession(in: apiRepo)

        model.sessions = [busy, idle, waiting, finished]
        model.selection = .session(busy.id)
    }

    // MARK: - A long, busy session — text, thinking, tool calls, a diff, a plan, usage

    private static func makeBusySession(in repo: URL) -> AppModel.SessionSnapshot {
        var session = AppModel.SessionSnapshot(
            id: UUID(),
            projectID: repo,
            title: "Add rate limiting to the webhook handler",
            provider: "Claude Code",
            model: "claude-opus-5",
            branch: "zero/rate-limit-webhook-4a1",
            workspace: .currentCheckout,
            state: .running,
            initialPrompt: "Add rate limiting to the webhook handler, 100 requests per minute per client."
        )

        session.transcript.appendUserMessage(session.initialPrompt)

        let openingEvents: [AgentEvent] = [
            .thinkingDelta(
                "The webhook handler is in Sources/API/Webhooks/Handler.swift. I should check whether "
                    + "there's an existing rate limiter I can reuse before adding a new dependency."
            ),
            .textDelta("Let me look at the current handler and see what's already there."),
            .toolCall(ToolCall(id: "t1", name: "Read", input: "Sources/API/Webhooks/Handler.swift", status: .running)),
        ]
        for event in openingEvents { session.transcript.apply(event) }

        session.transcript.apply(.toolCall(
            ToolCall(
                id: "t1", name: "Read", input: "Sources/API/Webhooks/Handler.swift",
                output: "213 lines", status: .succeeded
            )
        ))

        session.transcript.apply(.textDelta(
            "No rate limiter yet. I'll add a small token-bucket limiter keyed by client id, checked "
                + "before the handler does any work."
        ))

        session.transcript.apply(.plan([
            PlanItem(id: "p1", title: "Add a token-bucket RateLimiter type", status: .completed),
            PlanItem(id: "p2", title: "Wire it into the webhook handler", status: .inProgress),
            PlanItem(id: "p3", title: "Add tests for the limit and the reset window", status: .pending),
        ]))

        session.transcript.apply(.toolCall(
            ToolCall(
                id: "t2", name: "Edit", input: "Sources/API/Webhooks/Handler.swift",
                output: nil, status: .running,
                edit: FileEdit(
                    path: "Sources/API/Webhooks/Handler.swift",
                    oldText: "func handle(_ request: Request) async throws -> Response {\n    let payload = try request.decode(WebhookPayload.self)",
                    newText: "func handle(_ request: Request) async throws -> Response {\n    guard rateLimiter.allow(clientID: request.clientID) else {\n        return Response(status: .tooManyRequests)\n    }\n    let payload = try request.decode(WebhookPayload.self)"
                )
            )
        ))
        session.transcript.apply(.toolCall(
            ToolCall(
                id: "t2", name: "Edit", input: nil, output: "applied", status: .succeeded,
                edit: FileEdit(
                    path: "Sources/API/Webhooks/Handler.swift",
                    oldText: "func handle(_ request: Request) async throws -> Response {\n    let payload = try request.decode(WebhookPayload.self)",
                    newText: "func handle(_ request: Request) async throws -> Response {\n    guard rateLimiter.allow(clientID: request.clientID) else {\n        return Response(status: .tooManyRequests)\n    }\n    let payload = try request.decode(WebhookPayload.self)"
                )
            )
        ))

        session.transcript.apply(.toolCall(
            ToolCall(id: "t3", name: "Bash", input: "swift test --filter WebhookHandlerTests", status: .running)
        ))
        session.transcript.apply(.toolCall(
            ToolCall(
                id: "t3", name: "Bash", input: "swift test --filter WebhookHandlerTests",
                output: "Test run with 6 tests in 1 suite passed after 0.412 seconds.",
                status: .succeeded
            )
        ))

        // Markdown-flavored on purpose: bold, inline code, a fenced block with a language tag, and
        // a heading — the shapes `MarkdownBody` renders, so the preview shows the rendering path
        // and not just a plain-text stand-in for it.
        session.transcript.apply(.textDelta(
            "Tests pass. The limiter uses `TokenBucket` and is checked in `RateLimiter."
                + "allow(clientID:)` **before** the handler does any decoding work, so a client "
                + "over the limit never even pays for a JSON parse.\n\n"
                + "## What changed\n\n"
                + "```swift\n"
                + "guard rateLimiter.allow(clientID: request.clientID) else {\n"
                + "    return Response(status: .tooManyRequests)\n"
                + "}\n"
                + "```\n\n"
                + "It resets on a rolling window rather than a hard reset at the minute boundary, "
                + "so a client can't burst right at the edge of two windows. See "
                + "[the RFC this follows](https://datatracker.ietf.org/doc/html/rfc6585) for the "
                + "429 semantics."
        ))

        session.transcript.apply(.usage(Usage(
            model: "claude-opus-5",
            inputTokens: 8_412,
            outputTokens: 1_205,
            cacheReadTokens: 42_300,
            cacheWriteTokens: 3_100,
            thinkingTokens: 890
        )))
        session.transcript.apply(.turnEnded(.endTurn))
        session.state = .idle
        return session
    }

    // MARK: - Other sidebar states

    private static func makeIdleSession(
        in repo: URL, title: String, branch: String
    ) -> AppModel.SessionSnapshot {
        var session = AppModel.SessionSnapshot(
            id: UUID(), projectID: repo, title: title, provider: "Claude Code", model: "claude-sonnet-5",
            branch: branch, workspace: .isolatedWorktree, state: .idle, initialPrompt: title
        )
        session.transcript.appendUserMessage(title)
        session.transcript.apply(.textDelta("I'll reproduce it first, then look at what's flaky about the teardown."))
        session.transcript.apply(.turnEnded(.endTurn))
        session.state = .idle
        return session
    }

    private static func makeWaitingSession(in repo: URL) -> AppModel.SessionSnapshot {
        var session = AppModel.SessionSnapshot(
            id: UUID(), projectID: repo, title: "Rotate the staging API key",
            provider: "Claude Code", model: "claude-sonnet-5",
            branch: "zero/rotate-staging-key-77c", workspace: .currentCheckout, state: .waitingPermission,
            initialPrompt: "Rotate the staging API key and update the deploy script."
        )
        session.transcript.appendUserMessage(session.initialPrompt)
        session.transcript.apply(.textDelta("I need to run this to regenerate the key and write it to the deploy config."))
        session.transcript.apply(.permissionRequested(
            PermissionRequest(
                id: "perm-1",
                toolName: "Bash",
                detail: "curl -X POST https://api.staging.internal/keys/rotate \\\n  -H \"Authorization: Bearer $ADMIN_TOKEN\" \\\n  -d '{\"service\":\"webhooks\"}' > deploy/staging.key",
                options: [
                    PermissionOption(id: "allow_once", kind: .allowOnce, label: "Allow Once"),
                    PermissionOption(id: "allow_always", kind: .allowAlways, label: "Allow Always"),
                    PermissionOption(id: "deny_once", kind: .denyOnce, label: "Deny"),
                    PermissionOption(id: "deny_always", kind: .denyAlways, label: "Deny Always"),
                ]
            )
        ))
        session.state = .waitingPermission
        return session
    }

    private static func makeFinishedSession(in repo: URL) -> AppModel.SessionSnapshot {
        var session = AppModel.SessionSnapshot(
            id: UUID(), projectID: repo, title: "Add OpenAPI docs for /webhooks",
            provider: "Codex", model: "gpt-5.1-codex",
            branch: "zero/openapi-webhooks-1d3", workspace: .isolatedWorktree, state: .finished,
            initialPrompt: "Document the /webhooks endpoints in the OpenAPI spec."
        )
        session.transcript.appendUserMessage(session.initialPrompt)
        session.transcript.apply(.textDelta("Added the three /webhooks routes to openapi.yaml with request and response schemas."))
        session.transcript.apply(.usage(Usage(model: "gpt-5.1-codex", inputTokens: 3_204, outputTokens: 640, costUSD: 0.0412)))
        session.transcript.apply(.turnEnded(.endTurn))
        session.state = .finished
        return session
    }
}
