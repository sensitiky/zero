# Fix Plan — `Bundle.module` looks at the `.app` root, not `Contents/Resources`

## Branch / worktree
Branch: `fix/002-bundle-module-lookup-path`
Isolation mode: current checkout branch
Base: `develop`

## Root cause (one line)
This toolchain's generated `Bundle.module` resolves only `Bundle.main.bundleURL/Zero_ZeroCore.bundle`
(the `.app` **root**) or a build-time absolute path baked into the binary — never
`Contents/Resources/`, where `001`'s fix put the bundle — so in any build made off the dev machine
both candidates miss and the accessor `fatalError`s.

## Fix approach

Two changes. The packaging one alone is not enough, because the only layout that would satisfy the
accessor as written (a bundle at the `.app` root) **cannot be code signed** — measured, see
ANALYSIS.md. So the resource moves to the standard location *and* the app stops depending on an
accessor that crashes by design.

### 1. `Scripts/make-app.sh` — ship resources where a `.app` actually carries them

Replace the `*.bundle` → `Contents/Resources/` copy loop with one that copies each non-test resource
bundle's **contents** flat into `Contents/Resources/`, i.e. `pricing.json` lands at
`Zero.app/Contents/Resources/pricing.json`. That is the standard macOS location, it is what
`Bundle.main` reads, and `codesign --verify --strict` seals it cleanly (verified).

> **What actually shipped differs from step 2 below.** `Bundle.module` could not be dropped: under
> `swift test` `Bundle.main` is the toolchain's `swiftpm-testing-helper`, so nothing relative to it
> reaches the build products, and the baked `buildPath` is the only mechanism tests have. It is
> retained for dev/test and made *unreachable from a packaged app* by a `pathExtension != "app"`
> guard. A third change was also needed: `Scripts/make-preview.sh` had never shipped the resource
> at all. Both are written up under "Implementation findings" in ANALYSIS.md.

### 2. `Sources/ZeroCore/Pricing/PricingTable.swift` — never touch `Bundle.module` in a shipped app

`Bundle.module` `fatalError`s instead of returning nil, so it can never be used as a "try and fall
back" lookup. Resolve the URL explicitly, in order:

```swift
private static func pricingURL() -> URL? {
    // Packaged app: make-app.sh copies the resource into Contents/Resources.
    if let url = Bundle.main.url(forResource: "pricing", withExtension: "json") { return url }
    // swift run / swift test: SwiftPM's resource bundle sits next to the built binary.
    let sibling = Bundle.main.bundleURL
        .appendingPathComponent("Zero_ZeroCore.bundle", isDirectory: true)
        .appendingPathComponent("pricing.json")
    return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
}
```

`PricingTable`'s existing guard already degrades to `version: "unavailable"` with unknown costs when
the URL is nil (FR-30), so a missing resource becomes the honest documented behavior instead of a
crash. This removes the last `Bundle.module` reference from shipped code — the remaining uses are
all in `Tests/`, which run where the baked build path exists and are safe.

### 3. `Scripts/make-app.sh` — stop swallowing signing failures (recommended, separable)

Both `codesign` calls end in `|| true`, so the "unsealed contents present in the bundle root"
failure this bug's tempting fix would cause is silent — an unsigned app ships and nothing says so.
Drop the `|| true` on the app signature so packaging fails loudly instead. Say the word and I leave
this out; the new reproduction test already fails on an unsigned app either way.

## Files affected
- `Scripts/make-app.sh` — resource copy step (+ optional signing-failure hardening).
- `Sources/ZeroCore/Pricing/PricingTable.swift` — resource resolution.
- `Scripts/test-app-bundle.sh` — reproduction test (**already updated, currently failing**).

## Risks / side effects
- **Test path regression.** The sibling probe replaces `Bundle.module` for `swift test` too. If
  `Bundle.main.bundleURL` under `swift test` is not the products directory, the 5 existing
  `PricingTableTests` assertions on real pricing data fail loudly and immediately — a caught
  failure, not a silent one. If that happens I will report it rather than paper over it by keeping
  the crashing accessor.
- **Resource name collisions.** Flattening every target's resources into one `Contents/Resources/`
  would collide if two targets shipped a same-named file. Only `ZeroCore`/`pricing.json` exists
  today; the copy loop stays generic, and a collision would be a visible overwrite at package time.
- Low blast radius otherwise: one read-path function and one packaging script. No data, schema, or
  protocol surface touched.

## Rollback
Revert the two-file diff (`make-app.sh`, `PricingTable.swift`). No data or state migration. The
resource declaration in `Package.swift` is unchanged either way, so `swift test`/`swift run` keep
working exactly as before the fix.

## Verification
```
swift build && swift test              # 202 tests, incl. the 5 PricingTable assertions
bash Scripts/test-app-bundle.sh release  # must go FAIL -> OK
```
Plus a manual check that the rebuilt `Zero.app` opens a project and reaches the compose view — the
exact interaction in the report. Note that a *locally* built app cannot prove the fix (its baked
build path exists), which is precisely why the packaging assertion above is the real gate.
