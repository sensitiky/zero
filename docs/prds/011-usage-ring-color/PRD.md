# PRD — Color the usage ring by context severity using the accent token

## Status
In Progress (PRD + Plan approved by the user; implementation done and validated; awaiting user
testing — Gate 3)

## Problem
`UsageIndicator.ring` (`Sources/Zero/UsageIndicator.swift:37-63`) already fills a stroked circle by
context fraction and steps its *opacity* up once the fraction passes `Theme.Mark.gaugeWarning`
(0.85). It carries severity through weight alone. Every hue-based usage meter in comparable AI
provider UIs carries the same information through color as well, and a monochrome ring is a step
slower to read at a glance than those. The requested outcome is to recolor the filled arc with
`Theme.accent`, opacity-graded as it is today, so the ring reads a step faster without inventing a
new hue.

## Goals
- The filled (used-context) arc of the usage ring renders in `Theme.accent` instead of
  `Theme.foreground(scheme)`.
- The "nearly full" emphasis (opacity step at `Theme.Mark.gaugeWarning`) is preserved or refined,
  decided in the Plan phase.
- The change is documented as a deliberate, scoped exception to `Theme.accent`'s "one accent, one
  job" rule, not a silent widening of it.

## Non-goals
- No change to the unfilled track (`Theme.Stroke.track`) or the "unknown" dot fallback
  (`Theme.Mark.unknown`) — both stay monochrome.
- No change to `UsageDetail`, `PricingTable.contextFraction`, or cost display.
- No new hue: this reuses the existing `Theme.accent` value (`#8B5CF6`), not a new severity palette
  (no red/green, consistent with `docs/DESIGN.md`'s "no red and green" rule for the diff view and
  the app's general no-hue-for-state stance).

## User stories
- As a user glancing at the composer, I want the usage ring's fill to read as *the* accent color so
  that context pressure catches my eye the same way "the agent is waiting for you" does elsewhere in
  the app, without reading the numbers in the popover.

## Functional requirements
1. `UsageIndicator.ring`'s filled arc (`Sources/Zero/UsageIndicator.swift:43-51`) uses
   `Theme.accent.opacity(...)` instead of `Theme.foreground(scheme).opacity(...)`.
2. The existing two-tier opacity step (`Theme.Mark.gauge` = 0.75 below `Theme.Mark.gaugeWarning` =
   0.85, else full weight) is kept as-is, unless the Plan phase decides a revised tiering — in
   which case the revised tiering is documented in `PLAN.md` and here before implementation.
3. The unfilled track stroke and the "unknown" dot fallback are untouched — still
   `Theme.foreground(scheme)`-based.
4. `Scripts/lint-design-tokens.sh`'s accent-file allowlist (`EXPECTED` list, currently
   `Sources/Zero/Permissions/PermissionPrompt.swift` and `Sources/Zero/Sidebar/StateDot.swift`) adds
   `Sources/Zero/UsageIndicator.swift`, keeping the list's alphabetical sort so the lint still
   passes.
5. `docs/DESIGN.md`'s "The one accent" section (currently: "It appears in exactly two places... and
   `Scripts/lint-design-tokens.sh` fails the build if a third file references it",
   `docs/DESIGN.md:45-46`) is updated to state three places, including the usage ring's severity
   fill, and the "usage ring" line (`docs/DESIGN.md:162-166`) is updated to mention the new color
   treatment.
6. `docs/prds/004-ui-visual-overhaul/PRD.md`'s FR-8 (`:154-157`, Spanish) — which currently reads
   "Ningún otro uso... ni el anillo de uso" ("no other use... not the usage ring") — is amended to
   carve out this one additional, deliberate use, without otherwise weakening the "one accent, one
   job" rule for every other surface in the app.
7. `Sources/Zero/Theme.swift`'s doc comment on `accent` (`:30-32`), which explicitly lists "not...
   the usage ring" as a use the accent does *not* cover, is updated to match — this is a fourth
   location that documents the old exclusivity and would otherwise contradict the shipped code.

## Non-functional requirements
- **Contrast.** `Theme.accent` is already measured at 4.39:1 against `ink` and 3.82:1 against
  `paper` (`Sources/Zero/Theme.swift:39-41`, `docs/DESIGN.md:35-43`), both above the 3:1 WCAG 1.4.11
  floor for non-text marks. The ring is a non-text mark, so no new measurement is required — this
  PRD only needs to confirm (not re-derive) that floor still holds, per Acceptance Criterion 6 of the
  ticket.
- **Accessibility (WCAG 1.4.1).** Color must stay redundant, never the sole carrier: the ring
  already carries the same information through fraction/arc-length and through the opacity step, so
  adding color is additive, not load-bearing on its own. No accessibility label change is needed —
  `helpText`/`accessibilityLabel` already describe the percentage in words.
- **No new dependency, no new token file.** This reuses `Theme.accent` and the existing
  `Theme.Mark` weights.

## Data model changes
None. No persisted or transmitted data changes.

## UI/UX notes
- Affected view: `UsageIndicator.ring` (`Sources/Zero/UsageIndicator.swift`), rendered in both
  composers per `docs/DESIGN.md:162-166`.
- No new screens, no new popover content.

## Open questions
None outstanding for this PRD — the ticket records the accent color choice and the FR-8 exception as
already resolved at Gate 1 by the user (`docs/requirements/011-usage-ring-color/TICKET.md`, "Open
questions: None — resolved at Gate 1: accent color chosen by the user."). The only remaining decision
deferred to the Plan phase is whether the two-tier opacity step is kept as-is or refined — see FR-2.

## Conflicts / dependencies

**This PRD edits a previously shipped PRD's documented scope, not new scope of its own.**
`docs/prds/004-ui-visual-overhaul/PRD.md` is `Status: Approved (gate 1, 2026-08-23)` and was merged
via PR #14 (`4654da9 feat(004-ui-visual-overhaul): material, single accent, rhythm and a real diff`).
Its FR-8 explicitly and by name excludes the usage ring from `Theme.accent`'s use ("Ningún otro
uso... ni el anillo de uso"). This PRD proposes changing that already-shipped requirement's text —
that is a retroactive edit to history, made because the user has explicitly approved the exception,
not a normal "add a new FR" — and it should be reviewed as such rather than as ordinary net-new
scope.

Three other locations currently assert the same "accent means exactly one thing, in exactly two
files" claim and would go stale if only the code and lint changed without them:
- `docs/DESIGN.md:45-46` ("It appears in exactly two places... a third file" — the enforcement
  itself becomes three files, not two).
- `docs/DESIGN.md:162-166` (describes the usage ring today with no mention of color).
- `Sources/Zero/Theme.swift:30-32` (doc comment on `accent` naming "not... the usage ring" as an
  explicit non-use) — **not called out in the originating ticket's feasibility notes**, found during
  this PRD's discovery pass. It must be updated in the same change or the code and its own inline
  documentation directly contradict each other.

No cross-repo dependencies. No other PRD or in-flight branch touches `UsageIndicator.swift`,
`Theme.swift`'s `accent`/`Mark` section, or `Scripts/lint-design-tokens.sh`'s `ACCENT_FILES` check
(checked via `git log`/`grep` at discovery time).

**Slug/id note.** This item was assigned the slug `011-usage-ring-color` and branch
`feat/011-usage-ring-color` before this discovery pass ran. `009` is already in use by a merged,
unrelated bug fix (`docs/bugs/009-session-model-not-applied`, `40a22c3 fix(009-session-model-not-
applied): forward picked model to Claude Code launch args (#23)`), and a further, distinct in-flight
worktree already claims `010` (`.worktrees/010-codex-version-check-fails`). The next actually free id
in the shared sequential pool (`docs/prds/` + `docs/requirements/` + `docs/bugs/`, currently highest
at `009`/`010`) is `011`, not `009`. This is a numbering collision, flagged here rather than
silently renumbered, since the slug and branch were set explicitly before this flow started; renaming
requires re-doing the isolation setup (new branch, new worktree, new file paths) and is a call for
the requester, not for this flow to make unilaterally.
