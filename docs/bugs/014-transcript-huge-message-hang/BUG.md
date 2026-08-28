# Bug — App opens but shows nothing after build

## Status
Fixed

## Description
After `Scripts/make-app.sh` and `open build/Zero.app`, the app process launches and a window is
created, but nothing ever renders in it — the window stays effectively blank/unresponsive.

## Steps to reproduce
1. `cd Scripts && ./make-app.sh && cd ..`
2. `open build/Zero.app`
3. Wait — the window opens but shows nothing.

## Expected behavior
The app window shows the sidebar and the restored session's transcript shortly after launch.

## Actual behavior
The window is created (confirmed via `CGWindowListCopyWindowInfo`: onscreen, correct bounds,
alpha 1) but never paints content. The process pegs the main thread near 100% CPU indefinitely;
`RootView`'s `.onAppear` (which fires `StartupClock.reportFirstFrame()`) never runs, so first
frame never completes.

## Context
- Environment: local (macOS, this dev checkout)
- Affected commit / version: `develop` @ `41bca30`
- Affected users or records: reproduces on this machine because the local
  `~/Library/Application Support/the.stool.zero/Zero.store` holds a session with one
  247,142-character user message (see `ANALYSIS.md`) — anyone whose store accumulates a
  similarly oversized message will hit the same hang on next launch.
- Severity: High — app is unusable (main window never renders) once a session like this exists
  in the local store.

## Logs / stack trace
No crash report generated (`~/Library/Logs/DiagnosticReports`), no fatal/error entries in the
unified log for the process. `sample <pid> 3` shows the main thread's time entirely inside
CoreText glyph/line-layout calls (`TGlyphEncoder::RunUnicodeEncoderRecursively`,
`TLine::UpdateCachedMetricsForRun`, `TCharStreamIterator::GetChar`, …) — see `ANALYSIS.md` for
the full trace and root cause.
