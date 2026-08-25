# Fix Plan — Composer input lag with a large draft

## Branch / worktree
Branch: `fix/004-composer-input-lag`
Isolation mode: branch in the current checkout (off `develop` @ `bd7ba95`)

## Root cause (one line)
The composer's measured size depends on the **whole** draft, and the window's content-derived
minimum size makes AppKit ask for it twice per display cycle — so CoreText re-shapes the entire text,
with full pair kerning, on every frame.

## Fix approach

**The height of a field capped at 10 lines cannot depend on more than 10 lines of text.** Today it
depends on all of it. That is the entire bug, and the fix is to bound what gets measured.

`Composer` grows from 1 to 10 lines (`lineLimit(1...10)`). Ten lines is at most ~800 characters at
this measure. So the size query never needs to see more than a bounded prefix — a draft of 50 000
characters and a draft of 800 characters that both overflow 10 lines are **the same height**. Measure
a bounded prefix and the cost becomes `O(1)` in draft length, with the growth behaviour unchanged.

### Ladder — stop at the first rung that holds

Measured **in `Zero.app`** at each rung, not in a harness. This is not optional: every synthetic
harness used during analysis under-reported this bug by an order of magnitude, because none contained
the `NavigationStack` and content-derived window minimum that put the field on the display-cycle path
(ANALYSIS.md records the numbers).

1. **Give the field a definite height.** Compute it from a bounded prefix (≤ ~1 200 chars) and apply
   `.frame(height:)`, so ancestors get a concrete answer and never query the cell. Smallest diff:
   a few lines in `Composer.swift`, no new types, `TextField` retained.
2. **Take the window minimum off the content path.** Replace `.frame(minWidth: 900, minHeight: 560)`
   at `ZeroApp.swift:32` with the window's own `contentMinSize`. Removes the `updateConstraints`
   observer's 23% independently of rung 1 — worth doing if rung 1 leaves it.
3. **Replace the field with an `NSViewRepresentable` over `NSTextView`** at an explicit height, so
   `sizeThatFits` is constant by construction. Prototyped already (~2.5× in a bare harness). Largest
   diff by far: placeholder, focus ring, Return-to-submit vs Shift-Return, and the accessibility
   label all have to be reimplemented. **Only if 1 and 2 are insufficient.**

Expected to stop at rung 1, possibly 1+2. Rung 3 is written down so the ceiling is visible, not
because it is planned.

## Files affected

| File | Change |
|---|---|
| `Sources/Zero/Compose/Composer.swift` | bound the measured prefix; definite height on the field |
| `Sources/Zero/ZeroApp.swift` | rung 2 only — window `contentMinSize` instead of a content `.frame` |

Neither composer call site changes: `ConversationPane.swift:68` and `ComposeView.swift:29` both get
the fix by sharing the component. `ZeroCore` is untouched.

## Acceptance criteria

- At **50 000 characters** in the draft, typing continuously: main thread **< 30%** busy (from 77%),
  no wait cursor. Verified with `bash /tmp/catch-lag.sh` against the real app.
- `NSTextFieldCell cellSizeForBounds:` / `CTLineCreateWithAttributedString` no longer appear on the
  display-cycle path in the sample.
- Growth still 1→10 lines, and it still stops at 10.
- Placeholder, focus ring, Return-to-submit, `Stop`/`Send` swap, and the VoiceOver label all behave
  as before.

## Reproduction test — needs a decision

Phase 3 wants a failing test first. There is **no test target for the `Zero` executable** — the same
gap TESTING.md flags for `BridgeHostAdapter` — and a keystroke-timing test needs an `NSWindow` and a
real first responder, which is a poor fit for `swift test` and would be timing-flaky on CI.

Options, in order of preference:

- **A.** Extract the prefix-bounding as a pure function (`measuredPrefix(of:) -> String` or the
  line-count cap) and unit-test *that* in `ZeroCoreTests` — deterministic, no window, no timing. It
  tests the logic that makes the fix work, not the frame rate.
- **B.** Add a `ZeroTests` target and an opt-in performance test, skipped by default.
- **C.** No automated test; rely on the documented `sample` procedure.

**Decided: A** (user, 2026-08-25). The prefix-bounding is extracted as a pure function and unit-tested
in `ZeroCoreTests` — deterministic, no window, no timing. The frame-rate claim stays where it belongs:
a documented profile measurement in this file.

**Consequence worth stating.** Phase 3 normally wants a test that fails on today's code *before* any
fix exists. That is not achievable here: this bug's symptom is a frame-rate/saturation property of a
view hierarchy, and option A's test exercises the bounding function that the fix introduces. So the
test lands **with** the fix rather than before it, and the "currently broken" evidence is the profile
in ANALYSIS.md (77% main-thread saturation on the real app) instead of a red test. Recorded here
because it is a deliberate deviation from the flow, not an oversight.

## Risks / side effects

- **Height jitter.** If the prefix bound is too tight, a draft could size to fewer lines than it
  should. Mitigated by measuring well past 10 lines' worth (~1 200 chars for ~800 needed) and by the
  acceptance criterion that growth still reaches exactly 10 lines.
- **Rung 2 changes window behaviour.** Moving the minimum to `contentMinSize` must keep the window
  from being resized below 900×560. Checked by hand — drag the window small.
- **Rung 3 is a real rewrite** with genuine regression surface (focus, submit, accessibility). That is
  precisely why it is last.
- No data-model, persistence, provider or bridge code is touched. Nothing can affect a running agent.

## Rollback

Single-purpose branch, no migrations, no persisted state. `git revert` the fix commit; the composer
returns to today's behaviour, lag included. Rung 2 is a separate commit so it can be reverted
independently of rung 1.

## Security scans

Snyk SAST, Snyk SCA and SonarQube are **due before this fix's PR** and have **not** been run —
nothing is reported as clean. They were unavailable in this session (no Snyk MCP tool, `snyk` and
`sonar-scanner` both absent, no `run-sonnar.sh` in this repo), the same situation recorded for 005.
**WAIVED by the user on 2026-08-25.** `.claude/rules/security.md` requires Snyk SAST, Snyk SCA and
SonarQube before the review gate; none was run and none is reported as clean. The waiver is scoped to
this fix, which touches view layout only — no network, no persistence, no process spawning, no
provider or bridge code. It is recorded here rather than assumed.

---

## Amendment — after measuring rung 1 in `Zero.app` (2026-08-25)

**Rung 1: shipped, measured, insufficient.** 77% → **51%** main-thread busy at 50 000 characters.
Acceptance is < 30%, so the ladder continues. The full evidence is in ANALYSIS.md § *Second profile*;
the one-line reason: `.frame(height:)` pins one axis, and the `HStack` asks the field for the **other**
one — `_FrameLayout` with a free axis forwards the question to the child, which answers by having
CoreText shape the whole draft. 765 of the 1007 display-cycle samples are still that measurement.

Rung 1 **stays** — it is correct, it removed the height query, and every rung below needs a bounded
height anyway. It is just not the whole fix.

**Rung 2: dropped, and now for a defensible reason.** `NSHostingView.minSize()` is on the profile
(363 of the 765 measurement samples) but it is not caused by `ZeroApp.swift:32` — `NSHostingView`
computes its own minimum to publish the window's size constraints regardless of what the content
carries. Deleting that modifier cannot delete that branch. This matches the earlier harness result
("zero effect") and finally explains it. `ZeroApp.swift` is **no longer in scope for this fix.**

### Revised rung 3 — make the field's own answer `O(1)`

SwiftUI asks a leaf for its size at least once per layout pass, and there are two independent passes
per display cycle. There is no ancestor left to fix: both hot branches descend through the same
`_FrameLayout` into the same field. So the field's answer itself has to stop depending on how long
the draft is. `TextField` cannot do that — its answer is `NSTextFieldCell.cellSizeForBounds:`.

Cheapest first, each **measured in `Zero.app` at 50 000 characters** before moving down:

- **3a — definite frame on *both* axes.** One-line spike first: hardcode `.frame(width: 500, height: 200)`
  and re-sample. If `_overrideSizeThatFits` disappears, `_FrameLayout` short-circuits when neither axis
  is free, and the real fix is ~8 lines: field width = row width − trailing width, both read with
  `onGeometryChange`. If it does not disappear, 3a is dead and costs nothing.
  Risk if adopted: the trailing controls change width when `Send` swaps to `Stop`, so the width has to
  be re-read, not cached; and first-frame width is 0 until geometry reports.
- **3b — `TextEditor` instead of `TextField`.** `TextEditor` is greedy: it takes the offered size and
  does **not** size itself to its content, so its measurement is `O(1)` by construction. Costs a
  placeholder overlay, `.onKeyPress(.return)` for submit-vs-newline (Shift-Return keeps inserting), and
  `.textEditorStyle(.plain)` + the existing token background to keep the current look. ~30 lines in
  `Composer.swift`, no new type, no `NSViewRepresentable`.
- **3c — `NSViewRepresentable` over `NSTextView`** with `sizeThatFits` returning the bounded height and
  the proposed width, constant by construction. ~120 lines and it reimplements placeholder, focus ring,
  submit keys and the accessibility label. Last resort, unchanged from the original plan.

**Explicitly rejected: reducing the *number* of calls** (e.g. hiding the field in an `overlay`, whose
child size does not propagate). It would land around 10–13% busy and still be linear in the draft —
it moves the cliff instead of removing it. `ponytail:` this is the one place in this fix where the
smaller diff is the wrong one.

### Files affected — revised

| File | Change |
|---|---|
| `Sources/Zero/Compose/Composer.swift` | rung 1 (kept) + whichever of 3a/3b/3c holds |
| ~~`Sources/Zero/ZeroApp.swift`~~ | **out of scope** — rung 2 dropped, see above |

Acceptance criteria, reproduction-test decision (option A), risks and rollback are unchanged.

---

## Amendment 2 — rungs 3a and 3b measured out; 3c implemented (2026-08-25)

The three candidates were settled with probes rather than another of the user's typing sessions.
Probe sources kept at `/tmp/layoutprobe/` (`count.swift`, `typing.swift`, `height.swift`).

**Probe 1 — how many times, and over how much text, is the leaf asked for its size?** A
`NSViewRepresentable` standing in for SwiftUI's field bridge, counting its own `sizeThatFits` calls,
inside the same `NavigationStack` / `HStack` / window-minimum structure as the app. Draft 49 972 chars:

| shape | `sizeThatFits` calls per pass | text measured per pass |
|---|---|---|
| no frame (pre-fix) | 29 | 1 449 k chars |
| `.frame(height:)` (rung 1, shipped) | 16 | 799 k |
| `.frame(maxWidth: .infinity, height:)` | 18 | 899 k |
| **`.frame(width:height:)` (rung 3a)** | **3** | **149 k** |
| `Color.clear.overlay { field }` | 3 | 149 k |

Two things fall out. Rung 1's 29 → 16 matches the observed 77% → 51% almost exactly, which is a good
sign the probe models the right thing. And **3 is the floor**: no framing reaches 0, because SwiftUI
asks a leaf for its size at least once per pass no matter what is above it. So rung 3a is a 5×
improvement that is *still linear in the draft* — at 200 000 characters it is back where it started.
**3a rejected: it moves the cliff, it does not remove it.**

**Probe 2 — is `TextEditor` `O(1)`?** No. Fresh-host timing put it at 15.8 ms per pass at 50 000 chars
against `TextField`'s 8.1 ms, and 57.9 ms at 200 000. A persistent-host version of the probe reported
a flat 0.12 ms — but an arrival check (does the AppKit view actually hold the draft?) showed the text
never reached it, so that number was of nothing happening. **3b rejected: worse where it is
measurable, unverifiable where it is not.** Worth recording that the arrival check is what stopped a
fourth wrong hypothesis from being adopted.

**Rung 3c implemented.** `ComposerTextView`, an `NSViewRepresentable` over `NSTextView` whose
`sizeThatFits` answers from a bounded prefix and never looks at the rest. Probe 3, timing the shipped
height function against what a `TextField` does:

| draft | shipped (bounded) | `TextField` (whole draft) |
|---|---|---|
| 496 chars | 161 µs | 147 µs |
| 4 960 | 311 µs | 709 µs |
| 49 972 | **312 µs** | 1 900 µs |
| 199 950 | **313 µs** | 7 609 µs |

Flat from 5 000 characters upward — 24× cheaper at 200 000 and, more importantly, **constant**. The
answer is also memoized on `(bounded prefix, width)`, since the 3 calls per pass share arguments and
every display cycle repeats them (a blinking caret is enough to cause one).

### What rung 3c costs, honestly

`Sources/Zero/Compose/ComposerTextView.swift`, ~165 lines, reimplementing what the framework's field
gave for free:

| behaviour | how it is preserved |
|---|---|
| placeholder | SwiftUI `.overlay` in `Composer` while the draft is empty (an overlay's size does not feed back into layout, so the cheap answer stays cheap) |
| Return sends / Shift-Return breaks the line | `textView(_:doCommandBy:)` intercepting `insertNewline(_:)`, checking the shift modifier |
| focus ring | `becomeFirstResponder` / `resignFirstResponder` on an `NSTextView` subclass, reported back to `Composer` — `@FocusState` cannot reach into an AppKit view, so it became plain `@State` |
| autofocus (`ComposeView`) | `makeFirstResponder` once, deferred a hop out of the SwiftUI update |
| VoiceOver label | `setAccessibilityLabel`, re-applied when it changes |
| growth 1→10 lines, then scroll | the bounded height above, inside an `NSScrollView` with auto-hiding scrollers |

Undo, spell-check, IME and text selection come from `NSTextView` and were not reimplemented.

`ZeroApp.swift` is untouched. `ComposerMetrics` and its tests are unchanged and still the fix's
deterministic coverage: the bounded prefix is now consumed by `ComposerTextView` instead of by a
`.frame(height:)`.

### Local verification

`swift build` clean · `swift test` 377 tests in 30 suites pass · `Scripts/lint-design-tokens.sh`
passes · `Scripts/make-app.sh` produces `build/Zero.app`.

**Still outstanding: the real-app measurement.** The acceptance criterion (< 30% main-thread busy at
50 000 characters, no `cellSizeForBounds:` on the display-cycle path) is a `sample` on the running
app and has **not** been taken for 3c. Nothing here claims the bug is fixed until it has.
