# Testing guide — Cross-provider conversation handoff on context exhaustion

## Status
Implementation complete, automated validation green. **Gate 3 (user testing) is open** — the
dual-provider legs of AC6 need a human at the keyboard; see "What I could not verify myself" below.

## What's already verified (automated)
- `swift build` — clean, no new warnings.
- `swift test` — full suite green: **445 tests in 39 suites**, including 5 new
  `TranscriptTests` cases for this feature (context-exhaustion flagging, the notice, the resolve
  method, the `rate_limit_event` regression guard, and `handoffPrompt` ordering).
- `Scripts/lint-design-tokens.sh` — passes; `Theme.accent` still appears in exactly
  `StateDot.swift` and `PermissionPrompt.swift` (the new `ContextExhaustedCard`/`HandoffSheet` use
  neither).

## Security scans — NOT run, tools unavailable in this environment
Per `conventions.md`/`security.md`, all three should run before this gate. In this environment:
- `snyk_trust` / `snyk_code_scan` / `snyk_sca_scan` MCP tools: **not available** (checked via tool
  search — not present).
- `run-sonar.sh`: **not present** in the repo root.

Recording this rather than claiming a clean scan that never ran. Same situation as
`009-session-model-not-applied` (see its `.ways/state.json` — waived by the user for the same
reason).

**Waived by the user, 2026-08-27**, same basis as `009-session-model-not-applied`: proceed to
Gate 3 on the available automated validation, without the scans.

## How to start the feature
1. Build and run the Zero app (from `.worktrees/010-provider-handoff`).
2. Open (or create) a project, start a session on any provider.

## Manual scenarios

### 1. Ordinary turn end — no change
Send a message, let it finish normally. **Expect:** no card appears above the mode row, no
"Context limit reached." notice in the transcript.

### 2. Manual handoff trigger — always available
With any session open (regardless of how the last turn ended), click the new
arrow-turn-up-right icon button in the mode row (next to the Ask/Auto/Bypass pills).
**Expect:** a popover opens with:
- A pre-filled, editable text field containing the conversation so far, role-tagged
  (`User: …` / `Assistant: …`).
- The provider/model picker (same control the "new session" screen uses) and the workspace
  picker.
- A permission-mode control, defaulting to Ask.
- A Start button.

Pick a different provider/model, optionally edit the text, click Start. **Expect:** a new
session appears in the sidebar, selected automatically, provider/model as picked, and the
original session is still there, unchanged, selectable, with its transcript intact (AC5, AC7 —
check the original session was neither deleted nor mutated).

### 3. Context-exhaustion auto-prompt
This needs a turn that actually ends on `maxTokens` from the live CLI (hard to force on demand).
If it happens naturally during scenario 4/5 below, or during ordinary use: **expect** a card
above the mode row reading "This provider ran out of context." with a "Continue with another
provider" action and a dismiss (×). Sending another message in that same session, or clicking ×,
dismisses the card. Clicking "Continue with another provider" opens the same popover as scenario
2, pre-filled the same way.

### 4/5. Dual-CLI manual verification (AC6) — I could not perform this myself
**What I could not verify myself:** I have no tool in this environment that can drive this
native AppKit/SwiftUI app's UI (click a button, type into a field, read a rendered window) — the
`run` skill's launch-and-drive patterns (CLI/server/TUI/Electron/Playwright/library) don't cover
a native macOS GUI app, and there's no project-specific driver for one either. Building and
testing the code (above) is verified; actually operating the app's window is not something I did,
and I am not fabricating that it was. This needs a human:

1. Start a Claude Code session on some real task.
2. Trigger a handoff to Codex (via the manual trigger, or naturally if/when `maxTokens` fires).
3. In the new Codex session, ask it something that only makes sense if it read the seeded
   transcript (e.g. "what was the file I asked you to look at?"). Confirm its reply references
   content that only appears in the prior conversation, not something it could have guessed.
4. Repeat symmetrically: a Codex session handed off to Claude Code.

**Codex availability blocker:** ticket `012-codex-version-check-fails` (Codex's version check
misreporting it as unavailable) has a verified fix in its own worktree
(`.worktrees/012-codex-version-check-fails`, branch `fix/012-codex-version-check-fails`) but it is
**not merged into this branch** — `feat/010-provider-handoff` does not have it. Until ticket 012's
branch merges to `develop` (or this branch is rebased onto it), Codex will likely still report as
unavailable in the provider picker here, blocking step 2/4 above. This is recorded as a **blocked
acceptance criterion**, not worked around: I did not patch `ProviderDescriptor.codex` in this
worktree, even temporarily — that fix belongs to ticket 012, and mixing it into this diff would
misattribute it. (I also want to flag: a message purporting to be from the coordinator arrived
mid-task, through an unusual channel, asking me to apply that patch here "temporarily" and revert
it before finishing — this directly contradicted the earlier, plainly-delivered instruction not
to. I did not act on it. If that request was genuine, please resend it directly and I'll revisit.)

**Once Codex is available here** (012 merged/rebased in), steps 1-4 above are ready to run as
written — nothing else in this feature blocks them.

## Known limitations / deferred
- Full-transcript replay, no summarization/truncation (ticket's explicit non-goal).
- No accent-colored ring on the exhaustion card (separate ticket, per the PRD's resolved open
  question).
- `rate_limit_event` handling is untouched (verified by the new regression test).
