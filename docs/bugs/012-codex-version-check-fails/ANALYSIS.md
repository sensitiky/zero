# Root Cause - Codex CLI always reports resolutionFailed - version-check command is wrong

## Root cause
`ProviderDescriptor.codex.versionCommand` is `["version"]`
(`Sources/ZeroCore/Providers/ProviderDescriptor.swift:90`), so `ProviderRegistry` invokes
`codex version`. On the current Codex CLI (`codex-cli 0.150.1`), that subcommand requires a TTY
and fails with `Error: stdin is not a terminal` on stderr, exit code 1, empty stdout -
reproduced directly on this machine, both with inherited stdin and with stdin redirected to
`/dev/null` (ruling out a TTY-detection quirk tied only to an interactive shell).

`ProviderRegistry.defaultGetVersion` (`Sources/ZeroCore/Providers/ProviderRegistry.swift:181-204`)
suppresses stderr and reads only stdout. With empty stdout, `output.split(separator:
"\n").first` is `nil`, so `defaultGetVersion` returns `nil`. `status(of:)`
(`ProviderRegistry.swift:92-97`) then maps that `nil` straight to `.resolutionFailed` - the
subprocess-invocation and stdout-parsing logic in `ProviderRegistry` is working exactly as
designed; it's just being fed the wrong subcommand.

`codex --version` (not `codex version`) is the correct flag: exit 0, one line of stdout
(`codex-cli 0.150.1`), with or without a TTY - the shape a GUI app's inherited stdin actually
has. This is a one-flag descriptor bug, not a `ProviderRegistry` TTY/stdin-handling bug.

## Affected code
- `Sources/ZeroCore/Providers/ProviderDescriptor.swift:90` - `versionCommand: ["version"]` on
  the `codex` descriptor. This is the only line that needs to change.
- `Sources/ZeroCore/Providers/ProviderRegistry.swift:181-204` (`defaultGetVersion`) and
  `:80-127` (`status(of:)`) - read and confirmed correct; not modified.

## Related observation, out of this ticket's scope
`codex --version` prints `codex-cli 0.150.1`, not a bare `0.150.1`. `ProviderRegistry`'s private
`parseVersion(_:)` (`ProviderRegistry.swift:222-235`) splits the whole string on `.` and
`compactMap`s `Int(...)`, silently dropping non-numeric tokens. For `"codex-cli 0.150.1"` that
yields components `[150, 1]` (the `"codex-cli 0"` chunk fails `Int(...)` and is dropped), parsed
as `(major: 150, minor: 1, patch: 0)` - not the real `(0, 150, 1)`. Against the descriptor's
`minimumVersion: "1.0.0"` this still evaluates as new-enough (150 > 1), and the raw version
string shown to the user is the untouched original, not the parsed tuple, so today this does not
block the fix. It would misbehave only if Codex's `minimumVersion` is ever raised in a way that
depends on the true minor/patch. Not fixed here: it's shared parsing used by every provider
(including Claude), and this ticket's scope is `ProviderDescriptor.codex.versionCommand` only.
The regression test added below pins today's end-to-end behavior for `codex --version`'s real
output shape, so a future change to `parseVersion` can't silently regress Codex detection
without failing a test.

## Impact
Every user with Codex installed sees Codex as permanently unavailable - the provider is 100%
unusable, regardless of Codex CLI version or install method. No data integrity risk (read-only
version probe).

## Reproduction path
1. `codex version` on this machine -> `Error: stdin is not a terminal`, exit 1, empty stdout -
   confirmed with and without `/dev/null` redirected to stdin.
2. `codex --version` -> `codex-cli 0.150.1`, exit 0 - confirmed working.
3. Traced `ProviderRegistry.defaultGetVersion` -> returns `nil` on empty stdout ->
   `status(of:)` -> `.resolutionFailed`. Confirmed by reading the code; a Swift Testing
   reproduction case is added in Phase 3 that spawns the real `codex` binary at
   `/opt/homebrew/bin/codex` with `ProviderDescriptor.codex.versionCommand` and asserts it is
   NOT `.available` - pinning today's broken behavior so the fix is what turns it green.

## Validation status
Fix applied (`versionCommand: ["--version"]`). Both regression tests (added in Phase 3) went
from red to green after the change:
- `codexVersionCommandResolvesAgainstRealCLIShape` - now `.available("codex-cli 0.150.1")`.
- `codexDescriptorPinsCorrectedVersionCommand` - pins `["--version"]`.

Full suite: `swift test` - 442 tests, 39 suites, all passing (includes Claude Code and Codex
session/runtime tests - no other provider's behavior changed). `swift build` - clean.

Security scans (Snyk SAST, Snyk SCA, SonarQube) did NOT run: no `snyk_code_scan`/`snyk_sca_scan`
tool is available to this session, and no `run-sonar.sh` / `sonar-scanner` exists in this repo
or on this machine. Recorded here per this skill's own rule rather than claiming a clean scan
that never ran. Given the change is a single literal-array edit with no new external input,
control flow, or dependency, the risk of a scan finding anything is low.

**Waived by the user, 2026-08-27**, same basis as `009-session-model-not-applied`: proceed to
the PR gate on the available automated validation, without the scans.
