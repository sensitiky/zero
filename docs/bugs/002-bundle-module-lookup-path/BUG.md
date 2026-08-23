# Bug — Released app still crashes on compose: `Bundle.module` looks outside `Contents/Resources`

## Status
Fixed

## Description
Opening a project and pressing "Choose Repository" crashes the released app instantly. The crash is
a `fatalError` inside SwiftPM's generated `Bundle.module` accessor, reached from
`PricingTable.bundled()` while `ComposeView` renders.

This is the **same crash `001-dmg-resource-bundle-crash` was meant to fix**, and that fix *is*
present in the shipped build — it copies the resource bundle into `Zero.app/Contents/Resources/`,
and the installed 0.1.2 does contain it. The fix put the bundle in the wrong place: this Swift
toolchain's generated accessor looks for it at the **`.app` root**, not in `Contents/Resources`.

## Steps to reproduce
1. Install the released `Zero-0.1.2.dmg` (from the GitHub Release) to `/Applications`.
2. Launch `Zero.app`.
3. Add / open a project in the sidebar.
4. Press "Choose Repository".
5. The app crashes as `ComposeView` renders.

## Expected behavior
The compose view renders. If `pricing.json` were genuinely unreachable, `PricingTable` already
degrades to `version: "unavailable"` with unknown costs (FR-30) — it should never crash.

## Actual behavior
Hard crash — `EXC_BREAKPOINT (SIGTRAP)`, `Swift.fatalError` from `Bundle.module`, before
`PricingTable`'s own graceful-degradation guard is ever reached.

## Context
- Environment: released DMG build, `/Applications/Zero.app`
- Affected commit / version: **0.1.2** (`cba29da`, the `develop→main` release of PR #9). Present
  since the first packaged build; `001`'s fix did not actually resolve it.
- Affected users: **100% of users of any DMG/CI build** on any machine that is not the developer's
  own. Not reproducible from a local `make-app.sh` build on the dev machine (see ANALYSIS.md).
- Severity: **Critical** — the released app is unusable; this is the first interaction a new user has.

## Logs / stack trace
```
Exception Type:  EXC_BREAKPOINT (SIGTRAP)
Termination Reason: Namespace SIGNAL, Code 5, Trace/BPT trap: 5

0  libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 172
1  Zero                closure #1 in variable initialization expression of static NSBundle.module + 584
2  Zero                one-time initialization function for module + 12
5  Zero                one-time initialization function for cached + 576
8  Zero                static PricingTable.bundled() + 112
9  Zero                closure #1 in closure #1 in closure #1 in ComposeView.body.getter + 2500
12 Zero                ComposeView.body.getter + 264
```

Full report: `EXC_BREAKPOINT`, incident `AAB61DDC-D00E-4A45-8784-DCC1F0C65310`, macOS 26.5.2
(25F84), Mac16,12, version 0.1.2 (1).
