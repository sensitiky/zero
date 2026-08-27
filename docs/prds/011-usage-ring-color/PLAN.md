# Implementation Plan — Color the usage ring by context severity using the accent token

## Branch / worktree
Branch name: `feat/011-usage-ring-color`
Isolation mode: separate worktree at `.worktrees/011-usage-ring-color` (set up before Phase 0, per
the orchestrating task's explicit instruction — not chosen interactively).

## Phases

### Phase A — Code: recolor the filled arc
- [x] A1. `Sources/Zero/UsageIndicator.swift` — in `ring`, change the filled-arc `.stroke(...)`
      color from `Theme.foreground(scheme).opacity(fraction > Theme.Mark.gaugeWarning ? 1 :
      Theme.Mark.gauge)` to `Theme.accent.opacity(fraction > Theme.Mark.gaugeWarning ? 1 :
      Theme.Mark.gauge)`. Leave the track `Circle().stroke(...)` and the "unknown" dot `Circle()
      .fill(...)` untouched (FR-1, FR-3).
- [x] A2. Confirm no other reference to `Theme.foreground(scheme)` inside `ring` needs to change —
      re-read the whole `ring` computed property after the edit to make sure the diff is exactly
      the one line (or two, if `Theme.accent` needs a scheme-independent form spelled out) intended.

### Phase B — Lint allowlist
- [x] B1. `Scripts/lint-design-tokens.sh` — add `Sources/Zero/UsageIndicator.swift` to the `EXPECTED`
      heredoc-style list, keeping alphabetical order (so it sorts between `Sources/Zero/Sidebar/
      StateDot.swift` and nothing after — actually falls before `Sidebar/` alphabetically: `P` <
      `S` < `U`, so append after `StateDot.swift`). Update the comment above `ACCENT_FILES` ("the
      accent is allowed in StateDot... and PermissionPrompt..., plus Theme.swift") to also name
      `UsageIndicator` and briefly say why (severity fill, not a status marker) (FR-4).
- [x] B2. Run `Scripts/lint-design-tokens.sh` locally against the Phase A change to confirm it now
      passes (it would fail today, before B1, since `Theme.accent` would appear in a third,
      unlisted file).

### Phase C — Docs: DESIGN.md
- [x] C1. `docs/DESIGN.md:45-46` ("The one accent" section) — change "It appears in exactly two
      places... a third file references it" to name three places and adjust the enforcement
      sentence to "a fourth file" (FR-5).
- [x] C2. `docs/DESIGN.md:162-166` (the usage ring paragraph under Color/Palette) — add a sentence
      stating the filled arc uses the accent token, opacity-graded by the existing gauge/
      gaugeWarning weights, and that this is the accent's second deliberate use (FR-5).

### Phase D — Docs: PRD 004 (previously shipped — edited, not extended)
- [x] D1. `docs/prds/004-ui-visual-overhaul/PRD.md` FR-8 (`:154-157`, Spanish) — amend "Ningún otro
      uso... ni el anillo de uso" to carve out the usage ring as a second, deliberate use, while
      keeping the "one accent, one job" framing intact for every other surface. Write the edit in
      Spanish, matching the surrounding document's language. Add a short editorial note (a sentence,
      not a changelog block) marking this as a post-ship amendment to an already-`Approved` PRD,
      with the date and reason (FR-6).
- [x] D2. Do **not** touch FR-9/FR-10 (redundancy, contrast-measurement rule) — they already apply
      generically to "the accent" and need no wording change; re-read them after D1 to confirm they
      still read correctly with the new second use in mind.

### Phase E — Docs: Theme.swift inline comment (found in discovery, not in the original ticket)
- [x] E1. `Sources/Zero/Theme.swift:30-32` — the doc comment on `accent` lists "not... the usage
      ring" as an explicit non-use. Update it to match the new, deliberate exception, keeping the
      rest of the comment's argument (redundancy, measured contrast) intact.

### Phase F — Tests / verification
- [x] F1. No unit-testable logic changed (a `Color` swap in a SwiftUI view body) — this is a visual
      change with no new branch or computed value to unit test. The existing accessibility label /
      help text logic is untouched and already covered by not needing a new test.
- [x] F2. Manual verification checklist (see Test plan) stands in for an automated test, per FR-1–3
      being purely presentational.
- [x] F3. Run `Scripts/lint-design-tokens.sh` (already covered by B2) as the one automated check
      this change must pass.

## Test plan
- **Unit tests:** none added — no new logic, only a token substitution in a `View`'s body (see F1).
- **Manual validation checklist:**
  - Open the app with a session whose model reports a context window; confirm the ring's filled arc
    renders in the accent violet (`#8B5CF6`) instead of the previous monochrome foreground, in both
    light and dark mode.
  - Drive (or simulate) `fraction` past `Theme.Mark.gaugeWarning` (0.85) and confirm the arc still
    steps to full opacity, now in accent color rather than full-weight foreground.
  - Confirm the unfilled track and the "unknown" dot (no context denominator) are still monochrome,
    unchanged from before this change.
  - Run `Scripts/lint-design-tokens.sh` and confirm a clean pass.
  - Visual contrast spot-check: accent-on-`ink` and accent-on-`paper` are unchanged numeric values
    (4.39:1 / 3.82:1) since no new color value is introduced — confirm by inspection that
    `Theme.accent` itself was not modified, only its call sites.
- **E2E tests:** none — no new user-facing flow, only a recolor of an existing element.

## Rollback notes
Single-file code change (`UsageIndicator.swift`) plus one config line
(`lint-design-tokens.sh`) plus three doc edits (`DESIGN.md`, PRD 004's FR-8, `Theme.swift` comment).
Revert is a straight `git revert` of the feature branch's commit(s) — no migrations, no persisted
state, no schema changes to unwind.
