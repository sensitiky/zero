# Bug — DMG build crashes on launch when composing

## Status

Fixed

## Description

The `Zero.app` downloaded from the GitHub release DMG crashes with a fatal trap as soon as the
compose UI is drawn (e.g. opening a repository for a new project). Building and running via
`swift run` locally does not reproduce it.

## Steps to reproduce

1. Download `Zero-0.1.0.dmg` from a GitHub Release, mount it, copy `Zero.app` to `/Applications`.
2. Launch `Zero.app`.
3. Open (or create) a project repository, reaching the compose view.
4. App crashes immediately (`EXC_BREAKPOINT` / `SIGTRAP`).

## Expected behavior

The compose view renders normally; the usage/pricing indicator shows pricing info, or degrades
silently if pricing data is unavailable — it never crashes the app.

## Actual behavior

Main thread crashes with `EXC_BREAKPOINT (SIGTRAP)`, `Terminating Process: exc handler`. Crash
signature: `libswiftCore.dylib _assertionFailure` called from `closure #1 in variable
initialization expression of static NSBundle.module`, one-time init of `PricingTable.cached`,
reached from `PricingTable.bundled()` inside `ComposeView.body.getter` (via `UsageIndicator`).

## Context

- Environment: production DMG build (`the.stool.zero` 0.1.0 (1)), macOS 26.5.2, arm64.
- Affected commit / version: introduced by `178f6aa` (CI/CD releases: tag, build y DMG) — the
  first release actually packaged as a distributable `.app`/DMG.
- Affected users or records: every user who installs the app from the released DMG; 100%
  reproducible on any compose interaction.
- Severity: Critical — the packaged app is unusable.

## Logs / stack trace

```
Exception Type:    EXC_BREAKPOINT (SIGTRAP)
Termination Reason:  Namespace SIGNAL, Code 5, Trace/BPT trap: 5

Thread 0 Crashed:
0   libswiftCore.dylib   _assertionFailure(_:_:file:line:flags:) + 172
1   Zero                 closure #1 in variable initialization expression of static NSBundle.module + 584
2   Zero                 one-time initialization function for module + 12
...
5   Zero                 one-time initialization function for cached + 576
...
8   Zero                 static PricingTable.bundled() + 112
9   Zero                 closure #1 in closure #1 in closure #1 in ComposeView.body.getter + 2500
...
12  Zero                 ComposeView.body.getter + 264
```

Full report attached by the user in the original report (macOS crash reporter, incident
`148E5291-94A1-4D0C-B7D4-4E8B29D6574A`).
