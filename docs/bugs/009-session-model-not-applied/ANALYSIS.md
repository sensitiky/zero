# Analysis — Session model picker has no effect on which model actually runs

## Root cause
`CreationConfig.model` (the user's picked model) is threaded through session creation/resume for
persistence only. Nothing on the path from `SessionRuntime.create`/`.resume` to
`ProviderRegistry.configuration(...)` ever turns it into a real provider argument:

- `ProviderRegistry.configuration(for:workingDirectory:extraArguments:)`
  (`Sources/ZeroCore/Providers/ProviderRegistry.swift:136-154`) builds
  `descriptor.launchArguments + extraArguments` and has **no model parameter at all**.
- The only `extraArguments` ever assembled, in `SessionRuntime.permissionArguments`
  (`Sources/ZeroCore/Session/SessionRuntime.swift:172-202`), are permission-hook flags and, on
  resume, `--resume <id>` (`SessionRuntime.swift:448`). Model never enters that list.
- `config.model` itself is used exactly once, in `store.createSession(... model: config.model ...)`
  (`SessionRuntime.swift:340`) — a display/persistence field, not an argument to the process.

Per provider:

- **Claude Code** — `ProviderDescriptor.claude.launchArguments` (`ProviderDescriptor.swift:76-81`)
  is the fixed list `["--print", "--output-format", "stream-json", "--input-format", "stream-json",
  "--verbose"]`. No `--model`.
- **Codex** — `CodexEncoder.encodeSessionNew` (`Sources/ZeroCore/Providers/Codex/CodexEncoder.swift:28`)
  hardcodes `"model": "codex-4o"` in the JSON-RPC `params`, with an existing
  `// TODO(B5): Should this be configurable?` acknowledging the gap.
- **ACP** — `ACPEncoder.encodeSessionNew` (`Sources/ZeroCore/Providers/ACP/ACPEncoder.swift:131-152`)
  sends only `cwd` and `mcpServers`. No model field, no TODO.

## Real-CLI verification
Per this project's own precedent (`Tests/ZeroCoreTests/Fixtures/claude-code/PROVENANCE.md` — "a
protocol is verified against the binary, not the docs"):

- `claude --help` (2.1.237, installed at `~/.local/bin/claude`) confirms a real
  `--model <model>` flag: *"Model for the current session. Provide an alias for the latest model
  (e.g. 'sonnet' or 'opus') or the model's full name."*
- The project's **own captured fixtures** already use it —
  `Tests/ZeroCoreTests/Fixtures/claude-code/PROVENANCE.md` documents the capture command as
  `claude --print --output-format stream-json --verbose --model claude-haiku-4-5-20251001 ...`.
  The fix for Claude Code is exactly the flag the project already knows works, just never added to
  `ProviderDescriptor.claude.launchArguments`/`ProviderRegistry.configuration`.
- `codex` is not installed on this machine — its `app-server` JSON-RPC model field could not be
  verified against the real binary. The hardcoded literal plus the existing `TODO(B5)` are treated
  as sufficient evidence of the bug; the exact correct field name for a live model override needs
  confirming against the installed `codex` binary or its JSON-RPC schema before that half of the
  fix is written.
- ACP's model mechanism (a `session/new` field vs. a separate method, and whether it's supported by
  a given ACP agent at all) is unverified — no `knownModels` are populated for ACP providers today,
  and the spec at `docs/prds/001-agent-chat-core/PRD.md:20` doesn't mention model selection
  explicitly. Treated as an open question for the fix plan, not assumed.

## Affected code
- `Sources/ZeroCore/Providers/ProviderRegistry.swift` — `configuration(for:workingDirectory:extraArguments:)`
- `Sources/ZeroCore/Providers/ProviderDescriptor.swift` — `claude.launchArguments`
- `Sources/ZeroCore/Providers/Codex/CodexEncoder.swift` — `encodeSessionNew`
- `Sources/ZeroCore/Providers/ACP/ACPEncoder.swift` — `encodeSessionNew`
- `Sources/ZeroCore/Session/SessionRuntime.swift` — `create`, `resume`, `permissionArguments`
  (where the model needs to flow into the launch/session-new call)

## Impact
Every session created through Zero, for all three providers, since the first commit
(`91b3499`). No data-integrity risk — this is a launch-configuration gap, not a persistence bug
(the picked model is stored and displayed correctly; it just isn't applied). Impact is
behavioral/cost: sessions silently run a different model than the one the user selected and
believes is running.

## Validation — security scans
`snyk_code_scan` / `snyk_sca_scan` tools are not available in this environment, and
`run-sonnar.sh` does not exist in the repo (`snyk` CLI also not on `PATH`). None of the three
scans required by this project's security rule ran. Not reported as clean — asked the user, who
waived them for this change (2026-08-27): a ~10-line, self-contained CLI-argument-construction
fix, no new dependencies, no external input parsing. Validation for this change is `swift build`
(clean) + full test suite (440/440 passing).

## Reproduction path
Deterministic, not intermittent: any session creation reproduces it, because the launch-argument
list is static and never conditioned on `config.model`. A unit test at the `ProviderRegistry`/
`SessionRuntime` boundary — asserting the built `AgentProcess.Configuration.arguments` (Claude
Code) and the encoded `session/new` JSON (Codex/ACP) contain the picked model — reproduces it
without touching a real subprocess. See `Tests/ZeroCoreTests/Providers/ProviderRegistryTests.swift`
and `Tests/ZeroCoreTests/Session/SessionRuntimeTests.swift` for the existing pattern.
