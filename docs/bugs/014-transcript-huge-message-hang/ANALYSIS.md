# Analysis — App opens but shows nothing after build

## Root cause
`MarkdownBody` (`Sources/Zero/Markdown/MarkdownText.swift`) renders a transcript message as one
or more `Text(...).textSelection(.enabled)` views with no cap on input length. It is used
directly by `UserMessage` and for assistant text (`Sources/Zero/Transcript/TranscriptView.swift`).
Nothing between the store and this view truncates, paginates, or virtualizes a message's content
before handing it to `Text`.

Feature `010-provider-handoff` seeds the composer with the entire prior transcript, serialized to
plain text, so a session can be started (or continued) with the whole conversation as one new
message. If that seeded text is sent as-is, it becomes a single stored message with no size
limit. On this machine, `~/Library/Application Support/the.stool.zero/Zero.store` holds exactly
that: session `provider=claude model=claude-sonnet-5 worktree=<this repo> branch=develop`, whose
first message (`sequenceNumber = 0`, `role = user`) is **247,142 characters**.

On launch, `ZeroApp.init()` calls `coordinator.restoreFromStore()` synchronously before the first
frame (by design, to avoid the sidebar flashing empty — see the comment in `ZeroApp.swift`).
`RootView` then renders that session's transcript, and `UserMessage` → `MarkdownBody` asks
CoreText to shape and line-break a quarter-megabyte, effectively single-paragraph run of text.
Sampling the hung process (`sample <pid> 3`) shows the main thread entirely inside CoreText
layout/shaping calls (`TGlyphEncoder::RunUnicodeEncoderRecursively`,
`TLine::UpdateCachedMetricsForRun`, `TCharStreamIterator::GetChar`, `TASCIIEncoder::Encode`, …) —
no crash, no error, just a main-thread layout pass that does not return in any reasonable time.
Because this happens before `RootView`'s `.onAppear` (which is what fires
`StartupClock.reportFirstFrame()`), the first frame never completes and the window — which AppKit
has already created onscreen (confirmed via `CGWindowListCopyWindowInfo`: correct bounds, alpha
1) — never paints anything. That is the reported "app opens but shows nothing."

This is a genuine gap, not bad local data: the handoff feature can legitimately produce a message
this size, and the render path that every stored message goes through on every launch has no
safeguard against it.

## Affected code
- `Sources/Zero/Markdown/MarkdownText.swift` — `MarkdownBody`, the shared render path for both
  user and assistant transcript entries. This is the one place to fix: every caller
  (`UserMessage`, the assistant-text case, `ThinkingBlock`) routes through it.
- `Sources/Zero/Transcript/TranscriptView.swift` — `UserMessage`, `row(for:)` (assistant case),
  `ThinkingBlock` — callers, unaffected by the fix itself.
- `Sources/Zero/ZeroApp.swift` — `restoreFromStore()` runs before the first frame, which is why
  this blocks the *entire* app rather than just one scroll position; not the bug itself, but why
  the symptom is a fully blank launch rather than a slow scroll to one message.

## Impact
- Everyone whose local store accumulates a message of this size (via handoff, or any other path
  that could someday write a large message) hits an effectively permanently blank app on next
  launch — there is no in-app way to recover short of finding and deleting the poisoned data from
  the SQLite store directly.
- No data corruption or loss: the store itself is intact: `sqlite3 Zero.store "SELECT
  length(ZCONTENT) FROM ZMESSAGE ORDER BY length(ZCONTENT) DESC LIMIT 1;"` → `247142`, and the
  session/message rows are otherwise well-formed.
- Only one session affected on this machine (`sqlite3 Zero.store "SELECT count(*) FROM ZMESSAGE
  WHERE length(ZCONTENT) > 10000;"` → `1`).

## Security scans — NOT run, tools unavailable in this environment
Per `conventions.md`/`security.md`, all three should run before the PR gate. In this
environment: `snyk_code_scan` / `snyk_sca_scan` MCP tools — not found via tool search;
`run-sonnar.sh` / `run-sonar.sh` — not present at the repo root. Same gap already recorded for
`009-session-model-not-applied` and `010-provider-handoff`. Not reporting these as clean since
they did not run.

**Waived by the user, 2026-08-28**, same basis as `009`/`010`: proceed to the PR gate on the
available automated validation (build, lint, full test suite, and the live repro against the
actual hung store) without the scans.

## Reproduction path
1. Have a store containing a session whose first message is very large (this machine already
   has one, from dogfooding `010-provider-handoff`).
2. Build (`Scripts/make-app.sh`) and launch `Zero.app` directly (not via `open`, to see stderr):
   `ZERO_MEASURE_STARTUP=1 ./build/Zero.app/Contents/MacOS/Zero`.
3. Observe: no `zero: first frame at …` line ever prints; `ps -o pcpu` on the process stays near
   100%; `sample <pid> 3` shows the main thread inside CoreText text-layout calls.
