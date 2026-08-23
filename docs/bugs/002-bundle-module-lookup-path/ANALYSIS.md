# Analysis — `Bundle.module` looks at the `.app` root, not `Contents/Resources`

## Root cause

This toolchain (Swift 6.3.3) generates a **two-candidate** `Bundle.module` accessor —
`.build/arm64-apple-macosx/release/ZeroCore.build/DerivedSources/resource_bundle_accessor.swift`:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("Zero_ZeroCore.bundle").path
let buildPath = "/Users/mariocorrea/Documents/Projects/zero/.build/arm64-apple-macosx/release/Zero_ZeroCore.bundle"
let preferredBundle = Bundle(path: mainPath)
guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
    Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
}
```

Both candidates miss in a released app:

1. **`mainPath` uses `Bundle.main.bundleURL`, not `resourceURL`.** For `/Applications/Zero.app`
   that resolves to **`/Applications/Zero.app/Zero_ZeroCore.bundle`** — the `.app` *root*, a sibling
   of `Contents/`. The `001` fix copied the bundle into `Contents/Resources/` instead, so this
   candidate has never existed in any shipped build. Verified on the installed 0.1.2:

   | Path | Present |
   |---|---|
   | `/Applications/Zero.app/Zero_ZeroCore.bundle` (what the runtime checks) | **no** |
   | `/Applications/Zero.app/Contents/Resources/Zero_ZeroCore.bundle` (what `001` shipped) | yes |

2. **`buildPath` is the absolute build directory baked in at compile time.** In the released binary
   it is the CI runner's path — confirmed with `strings` on the shipped binary:
   `/Users/runner/work/zero/zero/.build/arm64-apple-macosx/release/Zero_ZeroCore.bundle`. That
   directory does not exist on any user's machine.

Both candidates fail → `Swift.fatalError` → the `EXC_BREAKPOINT` in the report.

### Why `001` looked fixed, and why this never reproduces locally

`buildPath` on a **locally** built app points at this machine's own `.build/...`, which *does*
exist. So a local `make-app.sh` build resolves `Bundle.module` through the fallback and works
perfectly — no matter what `Contents/Resources` holds. The bug is invisible to every local test
and only appears once the binary is built somewhere else (CI) or run by someone else.

`Scripts/test-app-bundle.sh`, the reproduction test added for `001`, asserted the bundle was present
in **`Contents/Resources`** — which was true, and stayed true, while the app kept crashing. It
encoded the fix's assumption rather than the runtime's actual requirement, so it passed on a broken
build. That is the reason a "fixed and validated" bug shipped twice.

## Affected code

- `Sources/ZeroCore/Pricing/PricingTable.swift:64` — the **only** `Bundle.module` use in shipped
  code (all other uses are in `Tests/`, which run on a machine where `buildPath` exists and are
  therefore safe). This is the crash site and the fix site.
- `Scripts/make-app.sh:32-38` — copies resource bundles into `Contents/Resources/`, a location
  this accessor never consults.
- `Scripts/test-app-bundle.sh` — reproduction test asserting the wrong location.
- `Sources/Zero/UsageIndicator.swift` → `Sources/Zero/ComposeView.swift` — the render path that
  triggers the first `PricingTable.bundled()` call.

## Why the bundle cannot simply be copied to the `.app` root

The direct reading of the accessor suggests copying the bundle to `Zero.app/Zero_ZeroCore.bundle`.
**Tested, and it breaks code signing outright:**

```
$ codesign --force --sign - T.app          # with a .bundle at the app root
T.app: unsealed contents present in the bundle root
$ codesign --verify --strict T.app
T.app: code object is not signed at all
```

Removing that root-level bundle (resource in `Contents/Resources/` instead) signs and verifies
clean: `valid on disk`, `satisfies its Designated Requirement`. Anything at the `.app` root that
isn't `Contents/` is unsealable, so that layout would trade a crash for an unsigned app — and
would block notarization (G4) permanently.

**This is made worse by `make-app.sh` ending both `codesign` calls with `|| true`**: the signing
failure above would be swallowed and an unsigned app shipped silently. Discovered while testing
this; recorded here, and proposed as a small hardening in the fix plan.

## Impact

Every DMG/CI build is unusable at the first compose interaction — 100% of released-build users,
including every release from the first packaged build onward. No data integrity risk: the crash is
a read-path `fatalError` before anything is written. No data loss beyond the interrupted launch.

## Reproduction path

The bug needs a binary whose baked `buildPath` does not exist locally — i.e. a CI build, or a local
build with `.build/` moved away. Practical reproduction (approach-independent, fails today):

`Scripts/test-app-bundle.sh` asserts the packaged app can resolve `pricing.json` using **only paths
inside the app bundle** — mirroring what the accessor does on a user's machine, with `buildPath`
treated as absent. Today no such path exists, so it fails; after the fix it passes.

A full end-to-end check (launch the packaged app and confirm the pricing table loads) would need a
debug hook in the app to print and exit; not added — the packaging contract above is what actually
broke, twice, and it is the thing worth asserting.

## Implementation findings — two corrections to the fix plan

Both surfaced while implementing and are recorded because they changed the fix:

**1. `Bundle.module` could not be removed from `ZeroCore` entirely, as the plan proposed.** The
plan assumed the dev/test path could resolve the resource relative to `Bundle.main`. It cannot:
under `swift test`, `Bundle.main` is the *toolchain's* test host, not anything in the build
directory —

```
bundleURL      = /Applications/Xcode.app/.../usr/libexec/swift/pm
executablePath = /Applications/Xcode.app/.../usr/libexec/swift/pm/swiftpm-testing-helper
```

so no `Bundle.main`-relative probe can ever reach `.build/`. That is exactly *why* SwiftPM bakes an
absolute `buildPath` into the accessor: for tests it is the only mechanism that works. The first
attempt (probe `Bundle.main.bundleURL` and its parent for the resource bundle) failed the 5
`PricingTableTests` assertions immediately, which is the loud failure the plan predicted.

Final design: `Bundle.main` first (packaged app), then a `guard Bundle.main.bundleURL.pathExtension
!= "app"` before `Bundle.module` is ever mentioned. A packaged app therefore cannot reach the
`fatalError`-ing accessor at all — it degrades to unknown costs (FR-30) — while `swift test` /
`swift run` keep using the mechanism that actually works there. The crash is unreachable in a
shipped build by construction, not by getting the packaging right.

**2. `Scripts/make-preview.sh` never shipped the resource at all** — not even the misplaced nested
bundle `001` added to `make-app.sh`. `ZeroPreview.app` rendered real costs only because the baked
build path exists on the machine that built it. Same root cause, second caller, so it got the same
resource copy. Left unfixed, the preview's usage ring would read "unknown" everywhere for anyone
else, and `docs/DESIGN.md` is explicit that a preview which stops matching production is worse than
no preview.

## Verification performed

- `swift test` — 202/202 pass, including the 5 `PricingTableTests` assertions that load real
  pricing data (they are what guards the dev/test resolution path).
- `bash Scripts/test-app-bundle.sh debug` and `release` — went from FAIL to OK; also asserts
  `codesign --verify --strict`, which the tempting root-level-bundle fix would have broken.
- Packaged-app resolution proven directly: `Bundle(url: Zero.app)?.url(forResource: "pricing",
  withExtension: "json")` resolves to `Contents/Resources/pricing.json` (887 bytes), with no build
  directory involved.
- **End-to-end, simulating a user's machine:** the baked build path
  (`.build/arm64-apple-macosx/debug/Zero_ZeroCore.bundle`) was moved away and `ZeroPreview.app` —
  which renders the transcript and the usage ring, i.e. `UsageIndicator` → `PricingTable` — was
  launched. It stayed alive; before this fix that is precisely the condition that `fatalError`s.
- `.app` root contains only `Contents/`, so nothing is unsealable.

## Validation tooling gap

`snyk_code_scan` / `snyk_sca_scan` (MCP tools) and `run-sonnar.sh` are **not available** in this
environment — no `snyk` CLI on `PATH`, no `run-sonnar.sh` in the repo. Same gap recorded in
`001-dmg-resource-bundle-crash` and `001-agent-chat-core`. Not run for this fix, and not reported
as clean.
