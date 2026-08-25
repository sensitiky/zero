# Testing Guide — Persistent projects and sessions across app restarts

## Status
Ready for user testing.

## What was already verified automatically
- `swift build` — clean.
- `swift test` — **391 tests passing** (was 385 before this branch; +6 net after 3 pre-existing
  tests were extended in place). New coverage: `Store.defaultModelContainer` path resolution and
  cross-instance durability, `upsertRepository` dedup, shared entry sequencing, `Transcript.
  restoring(_:)` (interleaving, the empty-anchor-message case, usage folding, permission requests
  never resurrected), `SessionState`/`ToolCall.Status` persisted-string parsing.
- `Scripts/lint-design-tokens.sh` — clean.
- `Scripts/make-app.sh` — builds `build/Zero.app` clean.
- **Smoke-tested against the real built app**, not just the test suite: launched
  `build/Zero.app`, confirmed `~/Library/Application Support/the.stool.zero/Zero.store` is
  created on first launch, inspected the on-disk SQLite schema directly (`ZPLANSNAPSHOTRECORD`
  table present, `ZTOOLCALLRECORD.ZSEQUENCENUMBER` column present), quit and relaunched cleanly —
  no crash, no new entry in `~/Library/Logs/DiagnosticReports/`.

What's below needs a person clicking through the real app — some of it (a moved folder, a `.dmg`
reinstall) isn't something this session can drive itself.

## How to test
1. Build and open the app:
   ```bash
   cd Scripts && ./make-app.sh && cd ..
   open build/Zero.app
   ```
2. Work through the scenarios below in order — each builds on the state the previous one left.

## Scenarios

### 1. Basic round-trip
1. Add a project (folder icon in the sidebar header) pointing at any git repository.
2. Start a session in it with a real prompt; let it run at least one turn, ideally one that makes
   a tool call and/or reports a plan.
3. Send one more message.
4. **Quit Zero (⌘Q). Reopen it.**
5. Expect: the same project, the same session, in the same place in the sidebar; the transcript
   shows the same messages, in the same order, tool call included; usage figures match what they
   were before quitting; **the session you had open is the one that's open again.**

### 2. Several projects, several sessions
1. Repeat scenario 1's setup with a second project, and a second session inside the first project.
2. Quit, reopen.
3. Expect: both projects present, each session under the right project, same relative order
   within each project as before quitting.

### 3. Quitting mid-turn
1. Send a message and quit **while the agent is still replying** (state shows running, or a
   permission prompt is up).
2. Reopen.
3. Expect: the session shows **idle**, not a stuck "running" spinner and not an inert
   Allow/Deny control nothing can answer. History up to that point is intact.

### 4. Resume vs. read-only
1. Select a **restored** Claude Code session that never hit a permission prompt or error — it
   should have a real provider session id under the hood. Expect it to reconnect and accept a new
   message normally.
2. Select a restored session from a provider without a verified resume path (or one you know has
   no provider session id). Expect it to open **read-only** — same message the existing
   "switched mode, no verified resume" path already shows elsewhere in the app, not a crash or a
   silently-ignored Send.
3. Either way: confirm this reconnect only happens for the session you actually clicked —
   watch Activity Monitor (or `ps`) right after relaunch, before selecting anything, and confirm
   no provider CLI process has started yet.

### 5. Moved/deleted folder
1. Quit Zero. Rename or move a project's folder on disk (or trash it).
2. Reopen Zero and select a session that was in it.
3. Expect: full history still shown. Sending a message is disabled. A notice explains the folder
   can't be found.
4. Move the folder back, reselect the session (or restart Zero). Expect sending works again.

### 6. `.dmg` reinstall survives
1. With data already present (scenarios 1–2 done), quit Zero.
2. Rebuild and reinstall over the existing app — e.g. re-run `make-app.sh`, or build/install the
   actual `.dmg` if that's part of your usual release flow.
3. Open the reinstalled app.
4. Expect: everything from before the reinstall is still there. (This is the core guarantee the
   PRD exists for — data in Application Support, not inside `Zero.app`, so replacing the app
   bundle whole doesn't touch it.)

## Known limitations (by design — see the PRD)
- Text that arrived both before and after an inline tool call shows as one merged block on
  restore, not split around the tool call the way it rendered live. The tool call itself still
  restores in the right position relative to everything else.
- A session's usage cost (`$`) may show as computed from the price table on restore even if the
  provider originally reported its own figure — that field isn't persisted. Token counts are
  unaffected.
- `thinking` blocks and relaunch-time notices ("switched to read-only") don't restore — they
  were never meant to (ephemeral by nature, not part of the conversation's content).

## Security scans — not run

Per `.claude/rules/security.md`, all three scans are required before this gate, and a scan that
didn't run must not be reported as clean:

- **Snyk SAST** (`snyk_code_scan` MCP tool) — not available in this environment (tool not found).
- **Snyk SCA** (`snyk_sca_scan` MCP tool) — not available in this environment (tool not found).
- **SonarQube** (`run-sonnar.sh`) — not available; no such script exists anywhere in this repo.

None of these ran. **Waived by the user 2026-08-25**, same as `004-composer-input-lag` — recorded
here and in `.ways/state.json`, not reported as clean.

## Reporting back
For each scenario: pass/fail, and if it fails, what you saw instead of what's listed under
"Expect". Screenshots of the sidebar/transcript are the fastest way to show a mismatch.
