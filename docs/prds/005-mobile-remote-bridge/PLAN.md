# Implementation Plan — Mobile Remote Bridge

## Branch / worktree

Branch: `feat/005-mobile-remote-bridge`
Isolation mode: **branch in the current checkout** (`/Users/mariocorrea/Documents/Projects/zero`)

The client half lives in a **separate repo** — `/Users/mariocorrea/Documents/Projects/zero-app`, on
`feat/001-zero-app-poc`, with its own PRD and plan. Nothing from that side lands here.

## The one shared artifact

`docs/prds/005-mobile-remote-bridge/CONTRACT.md` — frozen at this gate. Both sides are written
against it. It is the only thing the two plans have in common, which is what lets them run in
parallel.

## Shape of the change

```text
Sources/ZeroBridge/                 NEW target — no dependency but ZeroCore, Foundation,
  Server/                           Network, CryptoKit (all system)
    HTTPRequest.swift               parsed request value
    HTTPRequestParser.swift         incremental byte parser
    HTTPResponse.swift              status + headers + body → bytes
    WebSocketHandshake.swift        Sec-WebSocket-Accept (CryptoKit Insecure.SHA1)
    WebSocketFrame.swift            RFC 6455 encode/decode
    PairingCode.swift               CSPRNG 6 digits + constant-time compare
    BridgeServer.swift              NWListener + per-connection state machine
    ClientChannel.swift             one WS client, bounded send queue
    EventHub.swift                  fan-out by session id / global
  API/
    BridgeHost.swift                the protocol the app implements
    BridgeRouter.swift              method + path → handler
    DTO/…                           the contract, as Codable value types
    Projection.swift                ZeroCore types → DTOs (the tested mapping)

Sources/Zero/Bridge/                NEW — the adapter and the one surface
  BridgeHostAdapter.swift           BridgeHost over AppModel + SessionCoordinator
  BridgeController.swift            @Observable: on/off, port, code, client count, addresses
  BridgePanel.swift                 FR-27

Sources/Zero/SessionCoordinator.swift   +1 optional sink, published at 4 points (FR-24)
Sources/Zero/Sidebar/SidebarHeader.swift  + the control that opens the panel
Sources/Zero/Preview/PreviewData.swift    + both panel states
Package.swift                            + ZeroBridge, + ZeroBridgeTests, Zero depends on ZeroBridge
Tests/ZeroBridgeTests/                    NEW test target
```

Nothing in `ZeroCore` changes. No `@Model`, no migration, no change to `Scripts/make-app.sh` — the
bridge is code in the existing binary, not a new helper or resource.

**Why no `ZeroCore` change, when `AgentEvent.textDelta` carries no entry id.** The adapter reads the
affected entry out of the snapshot's `Transcript.entries` (already `public`) after `model.apply` has
run, and sends the entry's full current text with `mode: "replace"`. That is why v0 never sends
`append` — see CONTRACT.md. It also means the transport layer contains no copy of `Transcript`'s
assembly rules, which is FR-24's whole point.

## Phases

Phases A–D are pure and have no dependency on the app target: they are where the tests live, and
they can be written and run before anything is wired up. E–F are the wiring.

### Phase A — Target, contract types, projection

- [x] **A1** `Package.swift`: `ZeroBridge` target (`swiftLanguageMode(.v6)`, depends on `ZeroCore`),
      `ZeroBridgeTests` test target, `Zero` gains `ZeroBridge` as a dependency.
- [x] **A2** `API/DTO/`: every type in CONTRACT.md as a `Codable`, `Sendable` value type —
      `ProjectDTO`, `SessionSummaryDTO`, `SessionDetailDTO`, `EntryDTO`, `ToolCallDTO`,
      `PlanItemDTO`, `PermissionRequestDTO`, `PermissionOptionDTO`, `UsageDTO`, `BridgeEvent`,
      `HealthDTO`, `ErrorBody`, and the three request bodies.
- [x] **A3** `API/Projection.swift`: `SessionState → status` (FR-11, total, no `default:` — the
      compiler must fail when a sixth state appears), `Transcript.Entry → EntryDTO`,
      `ToolCall → ToolCallDTO`, `PermissionRequest`/`Usage`/`PlanItem` → their DTOs.
- [x] **A4** `affectedEntry(in:for:)` — pure: given `[Transcript.Entry]` and an `AgentEvent`, the
      entry that event touched (last entry for text/thinking/plan/notice, match by call id for a
      tool call). Mirrors `Transcript.upsert`'s identity rule and is tested against it.
- [x] **A5** `AgentEvent + affected entry → BridgeEvent?` (FR-22/23), including the events that
      produce nothing on the wire (`thinkingProgress`, `rateLimit(allowed)`, `unrecognized`).
- [x] **A6** Tests: every `SessionState` maps, every `Transcript.Entry` case encodes, every
      `AgentEvent` case either maps or is explicitly dropped, JSON keys match CONTRACT.md **field by
      field** (the test asserts the literal JSON, not a round-trip — a round-trip cannot catch a
      renamed key that both sides of Swift agree on).

### Phase B — HTTP and WebSocket, as bytes

- [x] **B1** `HTTPRequest` + `HTTPRequestParser`: incremental, fed arbitrary chunk boundaries.
      Request line, headers (case-insensitive), body by `Content-Length`. Caps: request line 8 KiB,
      header block 32 KiB, body 1 MiB. No force-unwraps. Over-cap or malformed → a typed failure the
      caller turns into `413`/`400` and a close.
- [x] **B2** `HTTPResponse`: status, headers, body, serialization. JSON content type by default.
- [x] **B3** `WebSocketHandshake`: detect the upgrade, compute `Sec-WebSocket-Accept`
      (`CryptoKit.Insecure.SHA1` + base64), build the `101`. Reject a bad version or a missing key.
- [x] **B4** `WebSocketFrame`: decode masked client frames (text, binary, close, ping, pong; 7 /
      16 / 64-bit lengths; continuation frames), encode unmasked server frames. Frame cap 1 MiB.
      A frame claiming more than the cap is a close, not an allocation.
- [x] **B5** `PairingCode`: 6 digits from `SystemRandomNumberGenerator`, leading zeros preserved,
      constant-time compare, `CustomStringConvertible` that does **not** print the code (so it
      cannot reach a log by accident).
- [x] **B6** Tests for B1–B5: split-chunk parsing, header case, the RFC 6455 example key, masking
      round-trip, fragmentation, oversize rejection, and a compare that is timing-independent by
      construction (fixed-length XOR-accumulate, asserted by reading the implementation, not by
      timing it — a timing test on a shared CI box is noise).

### Phase C — Listener, connections, fan-out

- [x] **C1** `BridgeServer` actor: `NWListener` on the port, accept loop, per-connection task.
      A connection starts in HTTP mode; an upgrade moves it to frame mode; anything else is served
      and (unless keep-alive) closed.
- [x] **C2** `ClientChannel`: one WS client. Bounded queue (256 frames), 30s ping, close on
      overflow with `1013`, close on peer close, and removal from the hub on either.
- [x] **C3** `EventHub` actor: subscribe by session id or globally, publish to matching channels,
      drop a channel that closed. Publishing never awaits a slow client.
- [x] **C4** Start/stop is idempotent; stop closes every channel and releases the port. Two starts do
      not leak a listener — the thing most likely to go wrong with a toggle.
- [x] **C5** Tests: a real listener on port 0 (an ephemeral port, so the suite never collides with a
      running Zero), a raw socket client doing a real handshake and a real frame exchange, fan-out to
      two subscribers, slow-client eviction, and stop-then-start on the same instance.

### Phase D — Router and endpoints

- [x] **D1** `BridgeHost` protocol: the eight operations, `async`, DTOs in and out, `Sendable`.
      No AppKit, no `AppModel` — `ZeroBridge` must not import the app.
- [x] **D2** `BridgeRouter`: pairing check first (FR-4), then method + path, then the handler.
      Unknown path → `404`. Every error shape from CONTRACT.md.
- [x] **D3** The eight HTTP endpoints (FR-7 to FR-17) against the protocol.
- [x] **D4** WebSocket routing: `/api/events` and `/api/sessions/:id/events`, pairing by query
      parameter, snapshot-first on the session stream (FR-20), `1008` for an unknown session.
- [x] **D5** Tests with a fake `BridgeHost`: every endpoint, every error status, a wrong pair on
      both transports, `422` carrying the project list, `409` carrying the coordinator's words, and
      snapshot-before-anything-else on subscribe.

### Phase E — The adapter

- [x] **E1** `SessionCoordinator`: one `var eventSink: (@MainActor (UUID, AgentEvent) -> Void)?`,
      called **after** `model.apply` in `pump`, plus three more publish points — `startSession`
      (session created), `send` (the user entry, as `entry.appended`), `answerPermission`
      (`permission.resolved`). Four lines and a property; no behaviour changes when the sink is nil.
- [x] **E2** `BridgeHostAdapter` (`@MainActor`): projects and sessions from `AppModel`, writes into
      `SessionCoordinator`. Resolves `project` by path then name (FR-14), returns the coordinator's
      `lastError` as the `409` message (FR-19), and rejects a stale `requestId` against
      `pendingPermission` (FR-17) before calling `answerPermission`.
- [x] **E3** State transitions: after each applied event the adapter compares the snapshot's status
      to what it last published and emits `session.state` / `session.summary` only on change — a
      `session.state` per delta would be most of the traffic and none of the information.
- [x] **E4** `BridgeController` (`@Observable`): port, pairing code, `isListening`, client count,
      and the reachable addresses (`getifaddrs`, IPv4, non-loopback). Off at launch, always (FR-2).

### Phase F — The surface

- [x] **F1** `BridgePanel`: state, address, pairing code in `Theme.code`, client count, Start/Stop.
      Tokens only — no literal radius, opacity, measure or animation, no new colour, the accent
      untouched. `@ScaledMetric` on any fixed frame; accessibility labels on the toggle and the code.
- [x] **F2** Reached from a control in `SidebarHeader` opening a `floating` popover — the pattern
      `UsageIndicator` already established, and the reason it is not a second sidebar or a settings
      window (DESIGN.md, "No second sidebar").
- [x] **F3** `PreviewData.seed()` covers both states, so `ZeroPreview.app` shows the panel off and
      listening with a code and a client count, without a phone on the network.
- [x] **F4** `./Scripts/lint-design-tokens.sh` green, and the accent still referenced in exactly the
      two files the lint allows.

### Phase G — Validation

- [ ] **G1** `swift build` and `swift test` clean; the new suite passes; no existing test regressed.
- [ ] **G2** `./Scripts/make-app.sh && open build/Zero.app` — the panel appears, the bridge binds,
      `curl` with the code gets a session list, `curl` without it gets `401`.
- [ ] **G3** Security scans (Snyk SAST, Snyk SCA, SonarQube) per `.claude/rules/security.md`. **This
      repo has no `run-sonnar.sh`** — if the tool is not available it is recorded in TESTING.md with
      the exact command that failed, and not reported as clean.
- [ ] **G4** `TESTING.md`: how to turn the bridge on, the `curl` transcript for every endpoint, the
      macOS local-network prompt to expect on first bind, and the end-to-end checklist shared with
      the app repo.

## Test plan

**Unit (`Tests/ZeroBridgeTests/`) — the FR each covers:**

| Suite | Covers |
|---|---|
| `ProjectionTests` | FR-11, FR-12, FR-13, literal JSON keys vs CONTRACT.md |
| `AgentEventMappingTests` | FR-22, FR-23, and the events that map to nothing |
| `HTTPRequestParserTests` | FR-1, caps, split chunks, malformed input |
| `WebSocketHandshakeTests` | FR-1, the RFC 6455 example, rejection cases |
| `WebSocketFrameTests` | FR-1, masking, fragmentation, oversize |
| `PairingCodeTests` | FR-4, digit shape, leading zeros, compare, no-leak description |
| `BridgeRouterTests` | FR-7…FR-19 against a fake host, every error status |
| `EventHubTests` | FR-21, FR-25, FR-26, slow-client eviction |
| `BridgeServerTests` | FR-1, FR-2, FR-20 — real listener on port 0, real handshake, snapshot first |
| `OffMainActorTests` | FR-6 — parsing and framing do not run on the main actor |

**Manual (in TESTING.md):** the loop of the POC's Definition of Done, driven first by `curl` and
`websocat`-equivalent from the Mac, then by the app. Plus: start/stop/start, wrong code, phone
sleeping mid-session, two clients on one session, Zero quit while a client is connected.

**Not tested, deliberately:** TLS (there is none), authentication beyond the code (there is none),
and behaviour across a Zero restart (sessions are in-memory — PRD Open question 5, resolved as
expected behaviour).

## Rollback notes

Additive and self-contained. Reverting is `git revert` of the branch's merge: `ZeroBridge` and
`ZeroBridgeTests` are new directories, `Sources/Zero/Bridge/` is new, and the three touched app files
change by a property, a call site, and a control in a header. **No data migration, so no data to
roll back.** With the toggle off — which is the default — the bridge does not run, so a bad version
in `develop` cannot listen on anything until someone clicks it.

## Parallelism

Once this gate closes, the two repos proceed independently against CONTRACT.md, one subagent each:

- **zero** — Phases A–D need no network peer and no client; E–F need only a running Zero.
- **zero-app** — its Phase C onwards can develop against a stub server built from CONTRACT.md, and
  switches to the real bridge at its Phase E.

They meet at the end-to-end checklist, which is the same list in both TESTING.md files.
