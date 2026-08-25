# PRD — Mobile Remote Bridge

## Status
Draft

## Problem

Zero runs on the Mac. The developer does not. A session takes minutes to tens of minutes, and for
all of that time the only way to know what it is doing — or to unblock it with a follow-up
instruction or a permission decision — is to be at the keyboard. An agent that stops to ask "may I
run this" and waits forty minutes for someone to walk back to the desk is not faster than doing the
work by hand.

Everything needed to answer *what is it doing* and *does it need me* already exists inside the app,
already normalized: `AppModel.sessions`, each with a typed `Transcript`, fed by one
`AsyncStream<AgentEvent>` per session. It simply cannot leave the machine. This adds the one thing
missing — a way out — and nothing else.

## Goals

- Expose the running app's projects, sessions, transcripts and live events over the LAN, readable
  and writable, as a **thin adapter over the existing runtime**.
- Duplicate no agent, session, provider or permission logic. One source of truth for what a session
  is doing, so the phone and the window can never disagree.
- Off by default; on with one click; paired with a 6-digit code shown in the window.
- No new SwiftPM dependency. This repo has none, and a server framework is not where that changes.
- Make a remote client able to complete the whole loop unattended: see sessions → open one → read
  it → send an instruction → watch it stream → answer a permission → see it finish.

## Non-goals

- Authentication beyond the pairing code — no accounts, no tokens, no sessions.
- TLS, internet exposure, relays, tunnels, port forwarding, Bonjour/mDNS discovery.
- Push notifications, background execution, running while Zero is closed.
- Multi-user, per-client authorization, audit trails.
- File upload/download, code editing, diff editing, git operations, terminal.
- Rehydrating session history from `Store` — the bridge shows what the window shows (see Open
  question 5).
- Any change to how agents run, how permissions are decided, or what a session is.

## User stories

- As a developer away from my desk, I want to see my running sessions and their state so I know
  whether anything needs me.
- As a developer, I want to read a session's conversation as it is written, so I do not have to wait
  for it to finish to know it went the wrong way.
- As a developer, I want to send a follow-up instruction to a live session so I can correct it
  without walking back.
- As a developer, I want to answer a permission request remotely so an agent is not blocked on my
  physical presence.
- As a developer, I want to stop a turn that is going nowhere.
- As a developer, I want to start a session in a project already open on my Mac.
- As the owner of the machine, I want the bridge off unless I turned it on, and I want a device to
  prove it was told the code before it can drive an agent that writes to my disk.

## Functional requirements

### Server

- **FR-1** A new `ZeroBridge` SwiftPM target: an HTTP/1.1 + WebSocket (RFC 6455) server on
  `Network.framework`, with no third-party dependency. One `NWListener`; a request carrying
  `Upgrade: websocket` completes the handshake and that connection switches to frame mode, every
  other request is served as plain HTTP.
- **FR-2** The bridge is **off by default**. It starts and stops only on explicit user action in the
  Zero window. Stopping closes every open connection.
- **FR-3** Port is configurable, default `4000`. Binds all interfaces (the point is the LAN). The
  listening address(es) are shown in the window so the user does not have to look up their own IP.
- **FR-4** **Pairing.** A 6-digit code is generated with a CSPRNG on each start and shown in the
  window. Every HTTP request must carry it as `X-Zero-Pair`; every WebSocket connection must carry
  it as a `pair` query parameter (React Native cannot set WebSocket headers portably). A missing or
  wrong code is `401` with no detail, and a WebSocket is closed without upgrading. The comparison is
  constant-time. The code is never written to a log, and never included in a response body.
- **FR-5** The bridge holds **no session state of its own**. Every read is a projection of
  `AppModel`; every write is a call into `SessionCoordinator`.
- **FR-6** Byte handling — accept, HTTP parse, WebSocket framing, JSON encode/decode — happens off
  the main actor. Only the projection of `AppModel` and the calls into `SessionCoordinator` hop to
  it, and they carry `Sendable` values across. (Inherits the NFR of `001-agent-chat-core`: no I/O or
  parsing on the main actor.)

### Read endpoints

- **FR-7** `GET /api/health` → `{ "app": "Zero", "version": "…", "sessionCount": n }`. It validates
  the pairing code, so "Connect" on the client is a real check rather than a reachability guess.
- **FR-8** `GET /api/projects` → the projects currently open in the window:
  `[{ "id": "/Users/…/millon-core", "name": "millon-core" }]`. `id` is the checkout path — the
  identity `AppModel.Project` already uses.
- **FR-9** `GET /api/sessions` → one summary per session: `id`, `title`, `summary`, `status`,
  `projectId`, `projectName`, `provider`, `model`, `branch`, `workspace`, `permissionMode`,
  `awaitingUser`, `updatedAt`.
- **FR-10** `GET /api/sessions/:id` → the summary plus `entries` (in order), `usage`, and
  `pendingPermission` when there is one. Unknown id → `404`.
- **FR-11** **Status mapping is explicit and total.** `SessionState` has five cases and the wire has
  five names, and they are not the same five:

  | `SessionState` | wire `status` | meaning |
  |---|---|---|
  | `.running` | `running` | the agent is working |
  | `.waitingPermission` | `waiting` | + `pendingPermission` — it needs a decision |
  | `.idle` | `waiting` | turn over, session alive, it needs an instruction |
  | `.finished` | `completed` | ended cleanly |
  | `.error(msg)` | `failed` | + `error` |

  `cancelled` is **never produced**: cancelling a turn in Zero leaves the session alive, so it
  reports `waiting`. The wire says so rather than inventing a state the runtime does not have.
  A client tells the two `waiting` kinds apart by `pendingPermission`, not by a second status.
- **FR-12** Entries are **typed on the wire**, one object per `Transcript.Entry` case
  (`userText`, `assistantText`, `thinking`, `tool`, `plan`, `notice`), each carrying the entry's own
  UUID as `id`. A client updates an entry in place instead of re-fetching the transcript, which is
  what makes streaming cheap. A flattened string here would be embedding a terminal at one remove.
- **FR-13** A `tool` entry carries the whole `ToolCall`: `name`, `status`, `input`, `output`,
  timings, and `edit` (`path`, `oldText`, `newText`) when the call edits a file. The client decides
  how much of it to show; the bridge does not decide for it by truncating.

### Write endpoints

- **FR-14** `POST /api/sessions` with `{ "project": "…", "prompt": "…", "provider"?, "model"?,
  "permissionMode"? }` → creates the session through `SessionCoordinator.startSession` and returns
  the created detail with `201`. `project` matches an open project by `id` (path) or by `name`. An
  unknown project is `422` **listing the valid ones** — the phone cannot show a folder picker, so
  the error has to be actionable. `provider`/`model` default to what the window remembers
  (`AppModel.draftProvider` / `draftModel`); `permissionMode` defaults to `ask`.
- **FR-15** `POST /api/sessions/:id/messages` with `{ "text": "…" }` → `SessionCoordinator.send`,
  `202`. The user message appears in the transcript at once, on both screens, exactly as it does
  when typed in the window.
- **FR-16** `POST /api/sessions/:id/cancel` → `SessionCoordinator.cancelTurn`, `202`. The turn ends;
  the session stays alive and reports `waiting` (FR-11).
- **FR-17** `POST /api/sessions/:id/permission` with `{ "requestId": "…", "optionId": "…" }` →
  `SessionCoordinator.answerPermission`, `202`. The options offered are exactly the ones the request
  carries, with their provider-native ids — never a hardcoded id, and never an option Zero invented.
  A `requestId` that is not the pending one is `409`: answering a request that already resolved must
  not resolve the next one.
- **FR-18** The decision from FR-17 travels as **`PermissionOrigin.userAction`**, unchanged. A human
  answered it; the only difference is which screen they were looking at. Nothing decoded from an
  agent or a tool result can reach this endpoint, so the guarantee `PermissionOrigin` exists to make
  (FR-25 of `001-agent-chat-core`) still holds — and the pairing code is what keeps "a human" from
  meaning "anyone on the café Wi-Fi".
- **FR-19** A write the coordinator refuses returns the coordinator's own message
  (`SessionCoordinator.lastError`, e.g. `checkoutBusy`) with `409`, so the phone shows what the
  window would have shown instead of a generic failure.

### Events

- **FR-20** `WS /api/sessions/:id/events` streams one session's events. **On connect the server
  sends one `session.snapshot` first**, carrying the same payload as FR-10. Without it there is a
  race no client can close: anything that happens between the `GET` and the socket opening is lost,
  and the transcript is quietly wrong from then on. With it, the client can skip the `GET` entirely.
- **FR-21** `WS /api/events` streams list-level changes — `session.created`, `session.state`,
  `session.summary` — so the sessions list refreshes on its own without polling.
- **FR-22** Wire event types: `session.snapshot`, `session.created`, `session.state`,
  `session.summary`, `agent.output`, `tool.call`, `plan`, `notice`, `permission.requested`,
  `permission.resolved`, `usage`, `session.completed`, `session.failed`. Every one carries
  `sessionId`.
- **FR-23** `agent.output` carries `entryId`, `kind` (`assistant` | `thinking`), `content` and
  `mode` (`append` | `replace`), mirroring how `Transcript.appendAssistantText` assembles a message:
  a delta appends to the open entry, and a new entry replaces nothing. The client applies deltas as
  they arrive and never waits for a complete response.
- **FR-24** The bridge subscribes to the **same normalized `AgentEvent` values the window renders**,
  through one additive hook in `SessionCoordinator.pump` — not by diffing `AppModel`, and not by
  opening a second subscription to `SessionRuntime.transcript`. Two subscriptions to one stream is
  two transcripts that drift; a diff of an observable model is a reimplementation of `Transcript`
  in the transport layer.
- **FR-25** Keepalive: the server answers WebSocket pings and sends one every 30s. A phone that
  sleeps produces a clean close rather than a half-open socket that looks connected and delivers
  nothing.
- **FR-26** Several clients may watch one session at once, and a client going away affects neither
  the session nor the other clients. The window is itself one more observer of the same stream.

### Desktop UI

- **FR-27** One surface in the Zero window: the bridge's state (off / listening), the address(es) it
  is reachable at, the pairing code, and how many clients are connected. Nothing else — this is a
  switch and a code, not a settings pane.
- **FR-28** It follows `docs/DESIGN.md` as written: tokens only (no literal radius, opacity,
  measure or animation), no new colour, the accent stays in its two existing places, the pairing
  code in `Theme.code` so it is readable across a desk, `@ScaledMetric` on any fixed frame,
  accessibility labels on the toggle and the code. `Scripts/lint-design-tokens.sh` stays green and
  `PreviewData.seed()` covers the surface in both states in the same change.

## Non-functional requirements

- **No third-party dependency.** `Network.framework`, `Foundation`, `ZeroCore`.
- **Off the main actor** (FR-6), and provably so: the tests assert where parsing runs, the way
  `AgentProcessTests` already does for the runtime.
- **Bounded memory.** Each client has a send queue with a cap; a client too slow to drain it is
  dropped with a close frame rather than allowed to grow it without limit. A stalled phone must not
  be able to exhaust the Mac's memory.
- **Bounded input.** Request line, header block and body each have a cap (body 1 MiB); a WebSocket
  frame has a cap. Anything malformed or over the cap closes the connection instead of allocating
  what the length field claims.
- Swift 6 language mode, strict concurrency, no force-unwraps in the parser or the frame codec.
- The pairing code, request bodies and transcript content are **never logged**.
- Every functional requirement above maps to at least one test in `ZeroBridgeTests`.
- First bind may raise the macOS local-network privacy prompt (macOS 15+). Documented in TESTING.md,
  not worked around.

## Data model changes

**None.** No new `@Model`, no schema change, no migration. `Repository`, `Session`, `Message`,
`ToolCallRecord`, `UsageRecord` and `PermissionRequestRecord` are untouched. The wire types are
`Codable` value types living in `ZeroBridge`, projected from `AppModel` on demand.

Changes to existing Zero code are additive and small, and this is the whole list:

| File | Change |
|---|---|
| `Package.swift` | `ZeroBridge` target + `ZeroBridgeTests`; `Zero` depends on `ZeroBridge` |
| `Sources/Zero/SessionCoordinator.swift` | publish each applied event to an optional observer (FR-24); publish user messages and session creation on the same channel |
| `Sources/Zero/AppModel.swift` | nothing, or at most an `updatedAt` on `SessionSnapshot` for FR-9 |
| `Sources/Zero/` (new file) | the adapter implementing the bridge's host protocol over model + coordinator |
| `Sources/Zero/` (new view) | FR-27's surface |
| `Sources/Zero/Preview/PreviewData.swift` | FR-28 |
| `Scripts/make-app.sh` | nothing — no new resource, no new helper binary |

## UI/UX notes

```text
Bridge

  Listening    http://192.168.1.10:4000

  Pair         418 205

  1 device connected                          Stop
```

Off, it is one line and a button. The code is the only thing on that surface with any visual weight,
because it is the only thing that gets read out loud.

## Open questions

1. **Port 4000.** It is what the POC spec says, and it is also a busy port on a developer's machine.
   Keep `4000` as the default (configurable), or pick something less contended?
2. **`cancelled` never appears on the wire** (FR-11), because Zero has no such state. Confirmed as
   correct, or do you want `POST /cancel` to end the session outright so the status exists?
3. **Remembering the toggle.** Should the bridge restart itself on next launch if it was on? The POC
   assumption is **no** — a listener that comes back on its own is a listener you forgot about.
4. **`allowAlways` / `denyAlways` from the phone.** Today `answerPermission` maps both to plain
   allow/deny and persists no rule, on either screen. The bridge exposes whatever options the
   request carries and inherits that behaviour exactly. Fine for the POC?
5. **Sessions are in-memory.** Nothing rehydrates `AppModel` from `Store` at launch, so after a Zero
   restart the phone sees an empty list even though the history is on disk. Out of scope here —
   confirm, since it is the one place the phone will look broken and not be.
6. **The `waiting` conflation** (FR-11): `.idle` and `.waitingPermission` share a status and are told
   apart by `pendingPermission`. Alternative is a sixth wire status. Recommendation: keep five, since
   the client needs the request payload anyway.

### Resolved at Gate 1 (2026-08-24)

- **Q1 — Port.** `4000` it is, configurable. Closed.
- **Q2, Q3, Q4, Q5, Q6** — the recommendation in each is accepted as written: no `cancelled` on the
  wire, the toggle does not persist across launches, `allowAlways`/`denyAlways` inherit the
  desktop's current behaviour, no `Store` rehydration, and five wire statuses with
  `pendingPermission` distinguishing the two `waiting` kinds.

## Conflicts / dependencies

- **`001-agent-chat-core`** — its NFR forbidding parsing/I/O on the main actor is what FR-6 exists
  to honour; its FR-25 (a permission can only be resolved by a named human origin) is what FR-18
  must not weaken.
- **`003-permission-modes`** — FR-17 must not bypass a session's mode. A `.bypass` session simply
  never emits a request to answer, and `.auto` resolves before the event would reach a client. The
  bridge adds no fourth mode.
- **`004-ui-visual-overhaul`** — the token lint and the `PreviewData` rule apply to FR-27/FR-28.
- **Consumer:** `zero-app` (`Projects/zero-app`, `docs/prds/001-zero-app-poc/PRD.md`) implements the
  client against this contract. This PRD owns the wire format; that one owns the client. Neither
  duplicates the other.
- No conflict with any open PRD: `004` is merged, and nothing here touches the transcript, the
  providers, the store or the permission broker.
