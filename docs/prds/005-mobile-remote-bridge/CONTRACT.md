# Wire contract — Zero Bridge v0

Frozen at Gate 2 of `005-mobile-remote-bridge`; amended at Gate 3 in three places the
implementation proved wrong or missing (the WebSocket pairing refusal, `not_found`, and the absent
`workspace` field) — each amendment is marked where it appears. **This file is the single source of truth** for what
travels between Zero Desktop and Zero App. The Swift server (`Sources/ZeroBridge`) and the React
Native client (`Projects/zero-app/models`) are both written against it and neither may extend it
without changing this file first.

Requirement ids referenced below are from `PRD.md` in this folder.

## Transport

- HTTP/1.1 and WebSocket on one port. Default **4000**, configurable. All interfaces.
- Every response is `application/json; charset=utf-8`, except `204`.
- Request bodies are JSON, capped at **1 MiB**. Larger, or malformed, closes the connection.
- `Connection: close` is honoured; keep-alive is supported for HTTP.

## Pairing (FR-4)

- HTTP: header `X-Zero-Pair: 418205`.
- WebSocket: query parameter `?pair=418205` (React Native cannot set WS headers portably).
- Wrong or missing → `401 {"error":"unpaired"}`, with no hint about the real code. A WebSocket is
  **refused during the handshake with that same HTTP `401` and never upgraded** — a close code
  requires a WebSocket to exist, so there is nothing to send `1008` on yet. (An earlier revision of
  this file said "closed with status `1008` before upgrading", which is self-contradictory; PRD FR-4
  says "closed without upgrading" and is the tiebreaker.) `1008` *is* used after a successful
  handshake, for an unknown session id.
- A client therefore cannot tell a wrong code from an unreachable host by watching a socket fail.
  That is why `GET /api/health` exists and why it validates the code: pairing is checked over HTTP,
  once, before any socket is opened.
- Constant-time comparison. Never logged, never echoed.

## Errors

Every non-2xx body is exactly:

```json
{ "error": "session_not_found", "message": "No session with that id is open in Zero." }
```

| status | `error` | when |
|---|---|---|
| 400 | `bad_request` | unparseable or missing fields |
| 401 | `unpaired` | FR-4 |
| 404 | `session_not_found` | unknown session id |
| 409 | `conflict` | the coordinator refused — `message` is its own words (FR-19), e.g. checkout busy |
| 409 | `stale_permission` | `requestId` is not the pending one (FR-17) |
| 413 | `too_large` | body over cap |
| 422 | `unknown_project` | plus `"projects": [ProjectDTO]` (FR-14) |
| 404 | `not_found` | unknown path, or a known path with the wrong method — distinct from `session_not_found`, which would tell a client its session vanished when it was the URL that was wrong |
| 400 | `bad_request` | also: an unknown `provider` id in `POST /api/sessions` |
| 500 | `internal` | anything else; `message` is safe text, never a transcript |

## Types

`status` — one of `running`, `waiting`, `completed`, `failed`, `cancelled`. The mapping from
`SessionState` is FR-11; `cancelled` is never produced by this version and exists so a client that
receives it renders rather than crashes.

`workspace` — `currentCheckout` | `isolatedWorktree`.
`permissionMode` — `ask` | `auto` | `bypass`.

### ProjectDTO

```json
{ "id": "/Users/mariocorrea/Documents/Projects/millon-core", "name": "millon-core" }
```

### SessionSummary

```json
{
  "id": "8B0C1D2E-3F40-5162-7384-95A6B7C8D9E0",
  "title": "Fix authentication bug",
  "summary": "Looking at the JWT validation flow in AuthGuard.ts",
  "status": "running",
  "projectId": "/Users/mariocorrea/Documents/Projects/millon-core",
  "projectName": "millon-core",
  "provider": "Claude Code",
  "model": "claude-opus-5",
  "branch": "zero/fix-authentication-bug",
  "workspace": "currentCheckout",
  "permissionMode": "ask",
  "awaitingUser": false,
  "error": null
}
```

`awaitingUser` is `true` only when a permission request is pending — the one thing the client's
accent is allowed to mark.

### SessionDetail

`SessionSummary` plus:

```json
{
  "entries": [Entry],
  "usage": Usage,
  "pendingPermission": PermissionRequest | null
}
```

### Entry (FR-12)

One object per `Transcript.Entry` case. `id` is the entry's UUID and is stable for its lifetime —
the client upserts by it.

```json
{ "id": "…", "kind": "userText",      "text": "Investigate the Auth0 issue." }
{ "id": "…", "kind": "assistantText", "text": "Looking at AuthGuard.ts…" }
{ "id": "…", "kind": "thinking",      "text": "The JWT check runs before…" }
{ "id": "…", "kind": "notice",        "text": "Rate limited: throttled" }
{ "id": "…", "kind": "plan",          "items": [PlanItem] }
{ "id": "…", "kind": "tool",          "call": ToolCall }
```

```json
PlanItem { "id": "1", "title": "Read AuthGuard.ts", "status": "pending|inProgress|completed" }
```

### ToolCall (FR-13)

```json
{
  "id": "toolu_01ABC",
  "name": "Read",
  "status": "pending|running|succeeded|failed|denied",
  "statusDetail": null,
  "input": "{\"file_path\":\"src/auth/AuthGuard.ts\"}",
  "output": "…",
  "edit": { "path": "src/auth/AuthGuard.ts", "oldText": "…", "newText": "…" },
  "startedAt": "2026-08-24T20:31:04Z",
  "endedAt": null
}
```

`edit` is `null` unless the call edited a file. `input`/`output` are sent whole — the client decides
what to show; the server does not truncate for it.

### PermissionRequest (FR-17)

```json
{
  "id": "req_7f2",
  "toolName": "Bash",
  "detail": "curl -s https://api.example.com/v1/token",
  "options": [
    { "id": "allow", "kind": "allowOnce",   "label": "Allow once" },
    { "id": "always","kind": "allowAlways", "label": "Allow always" },
    { "id": "deny",  "kind": "denyOnce",    "label": "Deny" }
  ]
}
```

`options` are exactly the ones the provider offered, with the provider's own ids. `detail` is
complete and is never truncated by either side.

### Usage

```json
{
  "model": "claude-opus-5", "inputTokens": 41233, "outputTokens": 1180,
  "cacheReadTokens": 38000, "cacheWriteTokens": 2100, "thinkingTokens": null,
  "contextWindowUsed": 41233, "contextWindowTotal": 200000, "costUSD": 0.42
}
```

Every field is nullable. A `null` `contextWindowTotal` means unknown, and a client must not draw a
fraction against a denominator it does not have.

## HTTP endpoints

| method | path | body | success |
|---|---|---|---|
| GET | `/api/health` | — | `200 {"app":"Zero","version":"0.1.0","sessionCount":3}` |
| GET | `/api/projects` | — | `200 [ProjectDTO]` |
| GET | `/api/sessions` | — | `200 [SessionSummary]` |
| GET | `/api/sessions/:id` | — | `200 SessionDetail` |
| POST | `/api/sessions` | `{"project","prompt","provider"?,"model"?,"permissionMode"?}` | `201 SessionDetail` |
| POST | `/api/sessions/:id/messages` | `{"text"}` | `202 {"ok":true}` |
| POST | `/api/sessions/:id/cancel` | — | `202 {"ok":true}` |
| POST | `/api/sessions/:id/permission` | `{"requestId","optionId"}` | `202 {"ok":true}` |

`project` in `POST /api/sessions` matches a `ProjectDTO` by `id` (path) or by `name`.

The body carries no `workspace`: a session started from the phone uses whatever the desktop's
remembered default is (`AppModel.draftWorkspace`). Choosing between the current checkout and an
isolated worktree is a decision about a machine you are not sitting at, and the desktop already
holds an answer to it.

## WebSocket

- `GET /api/sessions/:id/events?pair=…` — one session's stream. **The first frame is always
  `session.snapshot`** (FR-20).
- `GET /api/events?pair=…` — list-level stream. No snapshot; the client fetches
  `GET /api/sessions` once and then follows the stream.
- Text frames, one JSON object per frame. Server pings every 30s and answers client pings (FR-25).
- Unknown session id closes with `1008` after the handshake.
- A client whose send queue exceeds **256 frames** is closed with `1013` (FR: bounded memory).

### Events (FR-22)

Every event carries `type` and `sessionId`.

```json
{ "type": "session.snapshot",  "sessionId": "…", "session": SessionDetail }
{ "type": "session.created",   "sessionId": "…", "session": SessionSummary }
{ "type": "session.state",     "sessionId": "…", "status": "running", "awaitingUser": false, "error": null }
{ "type": "session.summary",   "sessionId": "…", "summary": "Reading AuthGuard.ts" }
{ "type": "agent.output",      "sessionId": "…", "entryId": "…", "kind": "assistant|thinking", "content": "…", "mode": "replace" }
{ "type": "tool.call",         "sessionId": "…", "entryId": "…", "call": ToolCall }
{ "type": "plan",              "sessionId": "…", "entryId": "…", "items": [PlanItem] }
{ "type": "notice",            "sessionId": "…", "entryId": "…", "text": "…" }
{ "type": "entry.appended",    "sessionId": "…", "entry": Entry }
{ "type": "permission.requested", "sessionId": "…", "request": PermissionRequest }
{ "type": "permission.resolved",  "sessionId": "…", "requestId": "req_7f2" }
{ "type": "usage",             "sessionId": "…", "usage": Usage }
{ "type": "session.completed", "sessionId": "…" }
{ "type": "session.failed",    "sessionId": "…", "error": "provider exited with status 1" }
```

**On `mode` (FR-23).** The contract allows `append` and `replace`; **v0 always sends `replace`**,
carrying the identified entry's full current text. `AgentEvent.textDelta` carries no entry identity —
`Transcript` assigns those — so an `append` implementation would have to reconstruct the assembly
rules in the transport layer, which is the one thing FR-24 exists to prevent. Re-sending a growing
message over a LAN costs nothing measurable; a client-side delta bug costs a wrong transcript that
looks right. `append` stays in the contract so a later version can use it without a wire change, and
a client must handle both.

`entry.appended` is how a `userText` entry reaches other clients: a message sent from the phone must
appear on the Mac and on any second phone, and it is not agent output.

`session.state` is emitted on every state transition, including the one that follows a cancel — which
is `waiting`, not `cancelled` (FR-11).

## What this contract deliberately does not have

No pagination (a transcript is bounded by a session), no ETags, no partial fetch, no compression, no
batching, no ordering sequence numbers. If the stream is lost the client reconnects and takes the new
snapshot as truth (client FR-26) — which is cheaper and more obviously correct than a resume cursor,
and is the reason the snapshot is mandatory.
