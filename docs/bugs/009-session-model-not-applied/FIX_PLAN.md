# Fix Plan — Session model picker has no effect on which model actually runs

## Branch / worktree
Branch: `fix/009-session-model-not-applied`
Isolation mode: current checkout branch

## Root cause (one line)
`config.model` is persisted for display but never turned into a `--model` launch argument for
the Claude Code subprocess.

## Fix approach

**In scope — Claude Code only**, the provider actually reachable end-to-end today (see Risks
below for why Codex/ACP are excluded):

1. Add a `SessionRuntime.modelArguments(provider:model:)` private static helper, next to the
   existing `permissionArguments(...)`: returns `["--model", model]` when
   `provider.id == ProviderDescriptor.claude.id && !model.isEmpty`, `[]` otherwise. Mirrors the
   existing pattern instead of inventing a new shape.
2. `SessionRuntime.create(with:...)` — append `modelArguments(provider: config.provider, model:
   config.model)` to `extraArguments` alongside the existing `permissionArguments(...)` call
   (`SessionRuntime.swift:270-275`).
3. `SessionRuntime.resume(sessionID:...)` — `Restored` currently doesn't carry the session's
   model. Add `model: String` to `Restored`, populate it from `session.model` in the existing
   `MainActor.run` fetch (`SessionRuntime.swift:402-413`), and append
   `modelArguments(provider: descriptor, model: restored.model)` alongside `permissionArgs`
   (`SessionRuntime.swift:436-449`) — so a resumed session keeps running the model it was created
   with, not the CLI's default.
4. No change to `ProviderDescriptor.claude.launchArguments` itself, no change to
   `ProviderRegistry.configuration(...)` signature — both stay generic; the model is providered
   the same way permission flags already are, as `extraArguments`.

Verified against the real CLI (`~/.local/bin/claude`, 2.1.237): `--model <alias-or-full-name>` is
a real flag, and it's the exact one this project's own captured fixtures already use
(`Tests/ZeroCoreTests/Fixtures/claude-code/PROVENANCE.md`).

**Reproduction test:** `SessionRuntimeTests.createPassesThePickedModelToClaudeCode` (added in
Phase 3) turns green once step 2 lands. A symmetrical resume-side assertion will be added in
Phase 5 alongside the existing `resumePassesTheProviderSessionID` test, covering step 3.

## Out of scope — filed as follow-up, not fixed here

While tracing the fix, found that `SessionRuntime.create`/`.resume` **always** construct the
runtime with `ClaudeCodeDecoder()`/`ClaudeCodeEncoder()` (`SessionRuntime.swift:359-360,458-459`),
regardless of `config.provider`. Codex and ACP sessions, if created through the real entry point
(`SessionCoordinator`), would be driven with Claude Code's wire protocol — a distinct,
pre-existing, and much larger bug than a missing model argument. Until that's fixed, `CodexEncoder`
and `ACPEncoder` (including Codex's hardcoded `"codex-4o"`) are not reachable from production code
at all, so "fixing" the Codex hardcode now would change nothing a user can observe and would risk
scope creep into an unrelated defect. Recommend filing it separately once this fix merges.

## Files affected
- `Sources/ZeroCore/Session/SessionRuntime.swift` — `modelArguments` (new), `create`, `resume`,
  `Restored`
- `Tests/ZeroCoreTests/Session/SessionRuntimeTests.swift` — reproduction test (done) + resume-side
  coverage (Phase 5)

## Risks / side effects
- Low. `--model` is additive and only appended for Claude Code, only when `model` is non-empty —
  no change to any other provider's launch arguments, no change to permission-hook wiring.
- A previously-persisted session whose `model` field is empty (pre-dates this fix, or was created
  through a path that never set it) resumes exactly as before — the CLI's own default — since the
  helper is a no-op for an empty string.

## Rollback
Revert the commit on `fix/009-session-model-not-applied`; no data migration, no persisted-schema
change, so a revert is a plain code revert.
