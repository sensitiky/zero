# Ticket — Color the usage ring by context severity using the accent token

## Status
Ready

## Problem / outcome
The usage ring already fills by context fraction, but it reads severity only through
opacity/weight, not color — harder to read at a glance than the colored usage meters other AI
provider UIs show. Recolor the ring's filled arc with `Theme.accent`, opacity-graded by fraction.

## Scope

**In**
- `UsageIndicator.ring`'s filled arc recolored to `Theme.accent`, opacity-graded by the existing
  `Theme.Mark.gauge` / `gaugeWarning` weights (or a refined tiering, decided in the plan phase).
- Update `Scripts/lint-design-tokens.sh`'s `ACCENT_FILES` allowlist to include `UsageIndicator.swift`.
- Update `docs/DESIGN.md` and FR-8 in `docs/prds/004-ui-visual-overhaul/PRD.md` to document the
  accent's extended scope.

**Out**
- The unfilled track and the "unknown" dot fallback stay on the existing monochrome treatment.
- No change to the `UsageDetail` popover, to `PricingTable.contextFraction`, or to cost display.

## Feasibility notes
- Directly possible, small diff: `UsageIndicator.ring` already draws a fraction-filled circle
  whose weight steps up past `Theme.Mark.gaugeWarning` (`Sources/Zero/UsageIndicator.swift:38-59`)
  — swapping its `Theme.foreground(scheme).opacity(...)` fill for `Theme.accent.opacity(...)` is
  the visual change itself.
- **Real conflict, now an accepted exception:** `Theme.accent` is a hard-enforced single-purpose
  token — "one accent, one job" (FR-8, `docs/prds/004-ui-visual-overhaul/PRD.md:154`), CI-checked
  by `Scripts/lint-design-tokens.sh` to appear in exactly `Sidebar/StateDot.swift` and
  `Permissions/PermissionPrompt.swift`. Extending it to the usage ring is a deliberate,
  user-approved exception — this ticket must update that lint's expected-file list and FR-8's
  documented scope, or CI fails on the first PR.

## Affected repositories / modules
| Repo | Modules touched | Nature of change |
|------|-----------------|-------------------|
| zero | `Zero/UsageIndicator.swift` | code |
| zero | `Scripts/lint-design-tokens.sh` | config (allowlist) |
| zero | `docs/DESIGN.md`, `docs/prds/004-ui-visual-overhaul/PRD.md` | docs (FR-8 scope) |

## Cross-repo dependencies
None.

## Acceptance criteria
1. The usage ring's filled (used-context) arc renders in `Theme.accent`, not
   `Theme.foreground(scheme)`.
2. The arc's opacity still steps up once the fraction passes `Theme.Mark.gaugeWarning` (or a
   revised tiering decided in the plan phase), preserving the existing "nearly full" emphasis.
3. The unfilled track and the "unknown" dot fallback are unchanged.
4. `Scripts/lint-design-tokens.sh` passes with `UsageIndicator.swift` added to the accent
   allowlist.
5. `docs/DESIGN.md` and FR-8 in `docs/prds/004-ui-visual-overhaul/PRD.md` are updated to state the
   accent's second, deliberate use, so "one accent, one job" no longer misdescribes the code.
6. Contrast in both light and dark mode checked against the same floors the rest of the palette
   already documents — no new hue introduced beyond the existing accent value.

## Risks / assumptions
Extending `Theme.accent` to a second meaning is a deliberate, user-approved exception to FR-8's
"exclusively" language — documented, not silently done.

## Open questions
None — resolved at Gate 1: accent color chosen by the user.

## Suggested flow
incu-way-development
