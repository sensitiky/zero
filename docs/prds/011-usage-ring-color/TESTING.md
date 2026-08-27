# Testing guide — Color the usage ring by context severity using the accent token

## How to start

```bash
cd .worktrees/011-usage-ring-color
swift build
open .build/debug/Zero.app   # or run from Xcode / swift run
```

Start (or resume) a session against a provider/model that reports a context window (e.g. Claude
Code with a Sonnet/Opus model), so `UsageIndicator.ring` has a `fraction` to draw.

## Scenarios

1. **Normal usage (fraction below 0.85).** Send a few messages until some context is used but
   still under 85%. The ring's filled arc should render in the accent violet (`#8B5CF6`) at
   `Theme.Mark.gauge` (0.75) opacity, in both light and dark mode — no longer the plain foreground
   token.
2. **Near-full context (fraction above 0.85).** Drive (or simulate, e.g. with a long conversation)
   the fraction past `Theme.Mark.gaugeWarning`. The arc should step to full opacity, still in accent
   color — the same "nearly full" emphasis as before, now carried in color too.
3. **Unknown context (no denominator).** Use a model/provider that does not report a context
   window. The ring should fall back to the small "unknown" dot, unchanged and still monochrome
   (`Theme.foreground(scheme).opacity(Theme.Mark.unknown)`) — this path is explicitly out of scope
   and must not pick up the accent.
4. **Track.** In every scenario, the unfilled ring track stays on
   `Theme.foreground(scheme).opacity(Theme.Stroke.track)` — unchanged.
5. **Popover unaffected.** Open the usage popover (click the ring). `UsageDetail`'s content
   (tokens, cost) is unchanged — no color change there (out of scope).

## Automated checks run

- `Scripts/lint-design-tokens.sh` — passed (accent now counted in exactly three files:
  `PermissionPrompt.swift`, `StateDot.swift`, `UsageIndicator.swift`).
- `swift build` — clean build, no new warnings introduced by this change.
- `swift test` — full suite, 440 tests / 39 suites, all passed. No new tests were added: this
  change is a `Color` token swap in a SwiftUI view body with no new branch or computed value (see
  `PLAN.md`, F1); the manual scenarios above are the verification for it.

## Known limitation / not run

**Snyk SAST, Snyk SCA, and SonarQube were not run** — the `snyk_code_scan` / `snyk_sca_scan` /
`snyk_trust` MCP tools and `run-sonar.sh` are not available in this environment (same gap recorded
for `009-session-model-not-applied`, where the user waived the scans for the same reason). This is
recorded here rather than reported as clean, per the security rule in
`.claude/rules/security.md`. Given the change is a one-line `Color` substitution plus documentation
edits — no new input handling, no new dependency, no new network/data path — the residual risk is
low.

**Waived by the user, 2026-08-27**, same basis as `009-session-model-not-applied`: proceed to
Gate 3 on the available automated validation, without the scans.

## Deferred items
None beyond the security-scan gap above.
