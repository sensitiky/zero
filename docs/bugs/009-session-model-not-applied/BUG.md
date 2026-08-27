# Bug — Session model picker has no effect on which model actually runs

## Status
Fixed

## Description
Zero's compose UI (`ProviderModelPicker`) lets you pick a specific model per provider before
starting a session — e.g. `claude-haiku-4-5` for Claude Code. That choice is stored for display
but never reaches the provider subprocess. Every session runs whatever model the provider CLI
defaults to (Claude Code) or a value hardcoded in the adapter (Codex), regardless of what was
picked.

## Steps to reproduce
1. Open Zero, start a new session against any repo with provider "Claude Code" and pick model
   `claude-haiku-4-5` in `ProviderModelPicker`.
2. Send a prompt and let the turn complete.
3. Compare the model reported by the CLI itself for that run (or its actual behavior/cost) against
   `claude-haiku-4-5`.
4. Repeat with provider "Codex" and any model typed into the free-text field.

## Expected behavior
The model selected in the compose UI is the model the provider subprocess actually runs for that
session — for every supported provider (Claude Code, Codex, ACP).

## Actual behavior
- **Claude Code**: the `claude` subprocess is launched with a fixed argument list
  (`--print --output-format stream-json --input-format stream-json --verbose`) that never
  includes `--model`. The CLI runs its own default model, independent of the picker.
- **Codex**: `CodexEncoder.encodeSessionNew` hardcodes `"model": "codex-4o"` in the JSON-RPC
  params it sends. Every Codex session runs that model, with an existing
  `// TODO(B5): Should this be configurable?` next to the hardcode.
- **ACP**: `ACPEncoder.encodeSessionNew` sends only `cwd` and `mcpServers` — no model field at
  all.

Symptom this was traced from: token/cost usage in Zero is higher than running the same provider
CLI directly from a terminal — consistent with the user's terminal habit of passing a cheaper/
faster `--model` explicitly, while Zero silently drops that choice and always runs each
provider's default/hardcoded model.

## Context
- Environment: all — reproducible on any session, any provider, macOS 26 dev toolchain per
  `docs/prds/001-agent-chat-core/PRD.md`.
- Affected commit / version: present since the first feature commit, `91b3499`
  (`feat(001-agent-chat-core)`) — not a regression from a later change.
- Affected users or records: every session created through Zero, for all three providers.
- Severity: High. Silent divergence between stated UI intent and actual behavior, with both a
  correctness impact (wrong model capability runs) and the cost/token impact that surfaced it.

## Logs / stack trace
None — this is a wiring gap, not a crash. See `ANALYSIS.md` for the exact code paths and the
real-CLI verification.
