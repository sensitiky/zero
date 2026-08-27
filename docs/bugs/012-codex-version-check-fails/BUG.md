# Bug — Codex CLI always reports resolutionFailed — version-check command is wrong

## Status
Fixed

## Description
Codex is installed and working, but `ProviderRegistry.status(of: ProviderDescriptor.codex)`
always returns `.resolutionFailed`, so Codex shows as unavailable in `ProviderModelPicker` and
cannot be selected for a new session.

## Steps to reproduce
1. Install the Codex CLI (confirmed present at `/opt/homebrew/bin/codex`, `codex-cli 0.150.1`).
2. Launch Zero and open the provider/model picker, or call
   `ProviderRegistry().status(of: ProviderDescriptor.codex)` directly.
3. Observe Codex reported as unavailable (`.resolutionFailed`) even though the CLI works.

## Expected behavior
`ProviderRegistry.status(of: ProviderDescriptor.codex)` returns `.available(version:)` and Codex
is selectable in `ProviderModelPicker`.

## Actual behavior
Status is `.resolutionFailed(reason: "Could not determine Codex version. Is it installed
correctly?")`.

## Context
- Environment: local (macOS, this machine)
- Affected commit / version: current `develop` (`ProviderDescriptor.codex.versionCommand =
  ["version"]`)
- Affected users or records: any user with Codex installed — Codex is never usable
- Severity: High (entire provider unusable)

## Logs / stack trace
```
$ codex version
Error: stdin is not a terminal
exit: 1

$ codex version </dev/null
Error: stdin is not a terminal
exit: 1

$ codex --version
codex-cli 0.150.1
exit: 0
```
