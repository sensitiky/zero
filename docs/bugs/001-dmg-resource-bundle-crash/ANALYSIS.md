# Analysis — DMG build crashes on launch when composing

## Root cause
`ZeroCore` declares a bundled resource (`Package.swift`: `resources: [.copy("Resources/pricing.json")]`),
so SwiftPM generates a `Bundle.module` accessor for that target backed by a *separate* resource
bundle, built at `.build/<arch>/<config>/Zero_ZeroCore.bundle`. `Scripts/make-app.sh` assembles
`Zero.app` by hand (no Xcode project) and only copies the `Zero` and `zero-permission-hook`
binaries plus the app icon — it never copies `Zero_ZeroCore.bundle` into
`Zero.app/Contents/Resources/`. When the app is launched from `/Applications`, SwiftPM's generated
`Bundle.module` initializer can't find that `.bundle` anywhere it looks and calls
`fatalError("unable to find bundle named Zero_ZeroCore")`, which is the `_assertionFailure` crash
frame in the report.

This is invisible under `swift run`/`swift test`: there, the built binary and
`Zero_ZeroCore.bundle` sit side by side in `.build/.../release/`, which `Bundle.module`'s fallback
search does find. Copying the binary out into `Zero.app/Contents/MacOS/` for packaging strips
that sibling, so only the packaged/DMG build is affected — consistent with this only surfacing
after `178f6aa` added the first real build+package pipeline.

`PricingTable.bundled()` itself already guards for a *missing `pricing.json` file* (falls back to
an empty, `"unavailable"` table) — that guard is fine and untouched by this fix. The crash happens
one layer below it, in `Bundle.module`'s own lookup, before that guard ever runs.

## Affected code
- `Scripts/make-app.sh` — assembles `Zero.app`, missing the resource-bundle copy step.
- `Package.swift` — `ZeroCore` target resource declaration (source of the generated bundle;
  correct as-is, just needs to be picked up by packaging).
- `Sources/ZeroCore/Pricing/PricingTable.swift` — `bundled()` / `Bundle.module` call site
  (crash site; no change needed here — see Fix Plan).
- `Sources/Zero/UsageIndicator.swift:10` — `PricingTable.bundled()` call that triggers the crash
  on first render.
- `Sources/Zero/ComposeView.swift:35` — renders `UsageIndicator`, matching the crash stack.

## Impact
100% of users launching the packaged DMG build hit this on the very first compose interaction —
the app is unusable as released. No data integrity risk (crash happens before anything is
written); no data loss beyond the interrupted session.

## Reproduction path
Build and package exactly like the release workflow does (`Scripts/make-app.sh release`, no
`swift run`), then launch the resulting `Zero.app` and open the compose view. `swift test` and
`swift run` do not reproduce it because the sibling `.bundle` is present in `.build/`.

## Validation tooling gap
`snyk_code_scan` / `snyk_sca_scan` tools and `run-sonnar.sh` are not available in this
environment (no `snyk` CLI, no `run-sonnar.sh` in the repo). Not run for this fix — see
Phase 6 note in the PR; the change itself is a one-line addition to a local packaging script
(no new dependency, no new external surface).
