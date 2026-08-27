# Ticket — Codex CLI always reports resolutionFailed — version-check command is wrong

## Status
Ready

## Problem / outcome
Codex is installed and working (`codex --version` → `codex-cli 0.150.1`, exit 0) but Zero cannot
detect it: `ProviderRegistry.status(of: .codex)` returns `.resolutionFailed` against the current
Codex CLI, so Codex shows as unavailable in `ProviderModelPicker` and cannot be selected for a new
session. Fix so Codex resolves as available.

## Scope
**In:** `ProviderDescriptor.codex.versionCommand` (or wherever root-cause analysis lands the real
fix).
**Out:** any other provider's descriptor; Codex's lack of a verified `--resume` flag (a separate,
already-documented limitation, not a regression from this bug).

## Feasibility notes / evidence
- `ProviderDescriptor.codex.versionCommand = ["version"]`
  (`Sources/ZeroCore/Providers/ProviderDescriptor.swift:90`) → `ProviderRegistry.defaultGetVersion`
  runs `codex version` (`Sources/ZeroCore/Providers/ProviderRegistry.swift:181-204`).
- Reproduced directly on this machine: `codex version` → `Error: stdin is not a terminal`, exit 1
  — with or without stdin redirected to `/dev/null`.
- `codex --version` → `codex-cli 0.150.1`, exit 0, works fine with non-tty stdin (the shape a GUI
  app's inherited stdin actually has).
- Root cause: wrong CLI flag baked into the descriptor, not a stdin/TTY handling bug in
  `ProviderRegistry` itself.

## Affected repositories / modules
| Repo | Modules touched | Nature of change |
|------|-----------------|-------------------|
| zero | `ZeroCore/Providers/ProviderDescriptor.swift` (codex descriptor) | code |

## Cross-repo dependencies
None. This ticket is a dependency **of** `008-provider-handoff`'s Codex-side manual verification —
another agent is working that ticket in parallel; land this one so their verification step can
proceed.

## Acceptance criteria
1. `ProviderRegistry.status(of: ProviderDescriptor.codex)` returns `.available` against a real,
   current Codex CLI install.
2. Codex is selectable in `ProviderModelPicker` after the fix.
3. A regression test pins the corrected `versionCommand` (and version-string parsing) so this
   can't silently regress.
4. No change to Claude Code's or any other provider's version-check behavior.

## Risks / assumptions
None beyond the fix itself — small, contained change.

## Open questions
None.

## Suggested flow
incu-way-bugs
