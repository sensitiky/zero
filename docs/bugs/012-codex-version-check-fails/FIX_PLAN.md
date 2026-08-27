# Fix Plan - Codex CLI always reports resolutionFailed - version-check command is wrong

## Branch / worktree
Branch: fix/012-codex-version-check-fails
Isolation mode: separate worktree (.worktrees/012-codex-version-check-fails)

## Root cause (one line)
`ProviderDescriptor.codex.versionCommand` is `["version"]`, but the real Codex CLI's `version`
subcommand needs a TTY and exits 1 with empty stdout; `--version` is the correct flag.

## Fix approach
Change `Sources/ZeroCore/Providers/ProviderDescriptor.swift:90` from
`versionCommand: ["version"]` to `versionCommand: ["--version"]`. No other line in the codex
descriptor, and no line in any other provider's descriptor, changes. `ProviderRegistry`'s
subprocess-invocation and stdout-parsing logic (`defaultGetVersion`, `status(of:)`) already
behaves correctly and needs no change - confirmed by reading it and by the two regression tests
below, which exercise it unmodified against both the current and corrected command.

Proposed diff (not yet applied):
```diff
-        versionCommand: ["version"],
+        versionCommand: ["--version"],
```

## Files affected
- `Sources/ZeroCore/Providers/ProviderDescriptor.swift` (1 line)
- `Tests/ZeroCoreTests/Providers/ProviderRegistryTests.swift` (already added, Phase 3 - two new
  regression tests, both currently red):
  - `codexVersionCommandResolvesAgainstRealCLIShape` - fakes the real CLI's exact shape
    (`--version` -> exit 0 + "codex-cli 0.150.1"; anything else -> exit 1 + stderr, no stdout)
    and asserts `status(of: .codex)` is `.available("codex-cli 0.150.1")`.
  - `codexDescriptorPinsCorrectedVersionCommand` - asserts
    `ProviderDescriptor.codex.versionCommand == ["--version"]` directly.

## Risks / side effects
None expected. This is a single literal-array change scoped to one field on one provider's
descriptor; `ProviderModelPicker` and `SessionCoordinator` consume `ProviderRegistry.status(of:)`
polymorphically and don't special-case Codex's version command. `ProviderDescriptor.claude` is
untouched, so Claude Code's version-check behavior is unaffected (acceptance criterion 4).

Noted but explicitly out of scope (see ANALYSIS.md "Related observation"): `parseVersion`'s
naive dot-split mis-parses `"codex-cli 0.150.1"` as `(150, 1, 0)` rather than `(0, 150, 1)`. It
happens to still compare correctly against `minimumVersion: "1.0.0"` today, and fixing it would
touch parsing shared by every provider. Left alone per the ticket's scope; flagged for a future
ticket if Codex's minimum version is ever raised in a way that depends on the true minor/patch.

## Rollback
Revert the one-line change in `ProviderDescriptor.swift` (and the two test additions) - no
migrations, no persisted state, no other callers to unwind.
