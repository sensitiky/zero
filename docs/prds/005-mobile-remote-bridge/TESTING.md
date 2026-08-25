# Testing guide — Mobile Remote Bridge

The end-to-end checklist below is **the same list** as the one in
`../../../../zero-app/docs/prds/001-zero-app-poc/TESTING.md`. One side must not be able to pass
while the other fails.

## Building and turning it on

```bash
cd ~/Documents/Projects/zero
./Scripts/make-app.sh && open build/Zero.app
```

The bridge is **off at launch, always** (FR-2). It is behind the antenna button at the right of the
sidebar header; the popover shows the state, the address, the 6-digit pairing code and the connected
client count.

**Expect a macOS local-network permission prompt on the first bind** (macOS 15+). That is the system
asking, not a bug, and it is not worked around — deny it and the phone cannot reach the Mac.

## Exercising it without a phone

With the bridge on and the code from the popover:

```bash
CODE=418205                     # whatever the popover shows
BASE=http://localhost:4000

curl -s -H "X-Zero-Pair: $CODE" $BASE/api/health      # {"app":"Zero","version":"…","sessionCount":n}
curl -s -H "X-Zero-Pair: $CODE" $BASE/api/projects
curl -s -H "X-Zero-Pair: $CODE" $BASE/api/sessions
curl -s -H "X-Zero-Pair: $CODE" $BASE/api/sessions/<id>

curl -s -X POST -H "X-Zero-Pair: $CODE" -H 'Content-Type: application/json' \
  -d '{"project":"millon-core","prompt":"List the files in src."}' $BASE/api/sessions

curl -s -X POST -H "X-Zero-Pair: $CODE" -H 'Content-Type: application/json' \
  -d '{"text":"Run the tests."}' $BASE/api/sessions/<id>/messages

curl -s -X POST -H "X-Zero-Pair: $CODE" $BASE/api/sessions/<id>/cancel
```

The checks that matter as much as the happy path:

```bash
curl -s -i $BASE/api/sessions                          # → 401 {"error":"unpaired"}
curl -s -i -H "X-Zero-Pair: 000000" $BASE/api/sessions # → 401, and no hint about the real code
curl -s -i -H "X-Zero-Pair: $CODE" $BASE/api/nope      # → 404 {"error":"not_found"}
curl -s -i -H "X-Zero-Pair: $CODE" $BASE/api/sessions/deadbeef  # → 404 session_not_found
```

From another machine on the LAN, substitute the address the popover shows for `localhost` — that is
the only way to test what the phone will actually do.

## The loop — the POC's Definition of Done

| # | Step | Pass when |
|---|---|---|
| 1 | Start Zero Desktop | The window opens with your projects |
| 2 | Turn the bridge on in Zero | It shows an address and a 6-digit pairing code |
| 3 | `bun start`, open the app | The connect screen appears |
| 4 | Enter the address and the code, Connect | It goes to the sessions list |
| 5 | Look at the list | Every session open on the Mac is there: title, status, project, summary |
| 6 | Open a session | Its conversation appears, in order, with the right shapes |
| 7 | Watch a running session | Assistant text grows progressively, without a refresh |
| 8 | Watch a tool call | One row that updates in place — pending → running → succeeded |
| 9 | Send an instruction | It appears at once, and the agent acts on it **on the Mac** |
| 10 | Watch the reply | It streams back to the phone |
| 11 | Trigger a permission request | The card appears on the phone, with the full detail and the real options |
| 12 | Answer it from the phone | The agent continues, **and the Mac window agrees** |
| 13 | Press Stop mid-turn | The turn ends and the status changes only after the runtime confirms |
| 14 | Start a new session from the phone | Project list loads, Start creates it, the app opens it |
| 15 | Let a session finish | It reports `completed`, on both screens |

### Bridge-specific cases

| Case | Expect |
|---|---|
| Stop the bridge with a client connected | Every connection closes; the phone shows disconnected, then reconnects when you start it again |
| Start → stop → start | Binds again on the same port. No leaked listener, and a **new pairing code** |
| Two clients on one session | Both stream; neither disturbs the other or the Mac |
| Quit Zero with a client connected | The phone reports unreachable rather than hanging |
| Cancel a turn | The session reports `waiting`, never `cancelled` — Zero has no such state |
| A `.bypass` session | No permission request ever reaches the phone; the agent just runs |

## What was verified automatically

| Check | Result |
|---|---|
| `swift build` | `Build complete!` |
| `swift test` | **370 tests in 29 suites passed** (was 269 before this branch — 101 new) |
| `./Scripts/lint-design-tokens.sh` | all five checks ✓, accent still only in `StateDot.swift` and `PermissionPrompt.swift` |
| `./Scripts/make-app.sh` | builds and signs `build/Zero.app` |
| `ZeroCore` modified? | **No** — `git diff --name-only` shows no `ZeroCore` path |
| Scope | 5 existing files changed (all additive), 39 new files |
| `build/Zero.app` launches | ✓ real bundle, ad-hoc signed, no crash — the 001/002 regression path |
| FR-2 off at launch | ✓ nothing bound on 4000 after launch, verified with `lsof` |

## G2 — verified against the real app, 2026-08-25

`./Scripts/make-app.sh` → `open build/Zero.app` → bridge started from the antenna popover by the
user (code shown, listener bound, macOS local-network prompt allowed). With it up, **24 assertions
against the real `BridgeHostAdapter`** — not a fake host — all passed (11 HTTP + 7 WebSocket +
6 multi-client):

| Group | Covered |
|---|---|
| Happy path | `GET /api/health` · `/api/projects` · `/api/sessions` → 200 |
| Pairing (FR-4) | no header → `401 unpaired`; wrong code → `401 unpaired` on both `/api/sessions` and `/api/health`, with no hint about the real code |
| Routing | unknown path → `404 not_found`; wrong method (`DELETE /api/sessions`) → `404 not_found`; unknown session → `404 session_not_found`; unknown project → `422 unknown_project` carrying `projects` |
| WS handshake | wrong code → **HTTP `401` during the handshake, never a `1008`** (contract amendment 1); right code → `101` with an RFC 6455-correct `Sec-WebSocket-Accept` (`s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` for the spec's own example key); server frames unmasked (§5.1) |
| Snapshot-first | `/api/sessions/:id/events` → first frame is `session.snapshot` for the id asked for; `/api/events` sends **no** snapshot and stays quiet until an agent event |
| Two clients, one session | both upgrade, both get their own snapshot, neither disturbs the other, and A disconnecting leaves B connected |

Not covered, because they mutate the developer's disk or need the phone: `POST /api/sessions`
actually starting an agent, `POST …/messages`, `POST …/cancel`, the permission round-trip, and
loop items 3–15 of the Definition of Done above.

`BridgeServerTests` binds a **real listener on port 0** and drives it with a hand-written raw
client — a real HTTP request, a real WebSocket handshake, real frames — so the byte layer is covered
end to end without a phone and without colliding with a running Zero.

## Security scans

**Waived by the user on 2026-08-24** for this POC. `.claude/rules/security.md` requires Snyk SAST,
Snyk SCA and SonarQube before this gate; none was run, and none is reported as clean. For the record
they were also unavailable: no Snyk MCP tool in the session, `which snyk` → not found,
`sonar-scanner` → not found, and this repo has no `run-sonnar.sh`.

The waiver is scoped to this POC. This feature opens a network listener that can start an agent with
write access to the developer's disk, guarded by a 6-digit code over cleartext HTTP — if it ever
outgrows a trusted LAN, these scans and a threat model are the first thing to reinstate.

## Contract amendments made during implementation

`CONTRACT.md` was frozen at Gate 2 and amended in three places the implementation proved wrong or
missing. Each is marked in that file:

1. **A wrong pairing code on a WebSocket is refused with HTTP `401` during the handshake, not a
   `1008` close.** The original wording ("closed with status `1008` before upgrading") was
   self-contradictory — a close code needs a WebSocket to exist. PRD FR-4 was the tiebreaker.
   Consequence, and it is load-bearing: a client cannot tell a wrong code from an unreachable host by
   watching a socket fail, which is why `GET /api/health` validates the code and why the app pairs
   over HTTP before opening anything. **Verified on the client side**: `lib/connection.tsx` calls
   `health()` on both connect and boot-restore.
2. **`404 {"error":"not_found"}`** added for an unknown path or a wrong method. Reusing
   `session_not_found` would tell a client its session had vanished when the URL was simply wrong.
3. **`POST /api/sessions` carries no `workspace`.** A session started from the phone uses the
   desktop's remembered default.

## Known limitations and deferred items

- **`BridgeHostAdapter` and `BridgeController` have no automated tests.** There is no test target for
  the `Zero` executable, and the plan's test table did not add one. FR-14/17/19 are covered at the
  router level against a fake host, but the adapter's real behaviour — project resolution by path or
  name, `lastError` → `409`, rejecting a stale `requestId` — is only exercised by hand, via the
  `curl` transcript above. It is now exercised by hand end to end — see **G2** above, which drives the real adapter through the real app for every read endpoint, every error status and both WebSocket routes. What remains untested is the *write* path (project resolution on session create, `lastError` → `409`, rejecting a stale `requestId`) and it has **no automated coverage at all**. That is the largest untested surface on this branch.
- **`ProtocolLogTests` (pre-existing, `ZeroCore`) is mildly flaky** — it sleeps 100ms then reads a
  file. The implementing agent saw it fail in 2 of ~15 full runs, and once in 11 runs with every
  bridge test skipped, so it is not caused by this work. I ran it 5 times in isolation and 2 full
  suites: all passed. It will occasionally redden a `swift test` run; it is not this branch's bug.
- **Sessions are in-memory.** Nothing rehydrates `AppModel` from `Store` at launch, so after
  restarting Zero the phone sees an empty list even though the history is on disk. PRD Open
  question 5, resolved at Gate 1 as expected behaviour.
- **`agent.output` always sends `mode: "replace"`** in v0. See CONTRACT.md for why, and note the
  client already handles `append` so a later version needs no client change.
- No TLS, no auth beyond the pairing code, no discovery, no rehydration, no background execution —
  all Non-goals, all deliberate.
