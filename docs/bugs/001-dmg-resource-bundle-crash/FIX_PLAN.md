# Fix Plan — DMG build crashes on launch when composing

## Branch / worktree
Branch: fix/001-dmg-resource-bundle-crash
Isolation mode: current checkout branch

## Root cause (one line)
`Scripts/make-app.sh` never copies the SwiftPM-generated resource bundle (`Zero_ZeroCore.bundle`)
into `Zero.app/Contents/Resources`, so `Bundle.module` can't find it in the packaged app and
`fatalError`s the first time `PricingTable.bundled()` runs.

## Fix approach
In `Scripts/make-app.sh`, after locating `$BIN` (the SwiftPM build output dir), copy every
non-test resource bundle from `$BIN` into `$APP/Contents/Resources/`:

```bash
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    case "$(basename "$bundle")" in
        *Tests.bundle) continue ;;
    esac
    cp -R "$bundle" "$APP/Contents/Resources/"
done
```

This is generic over any current or future target with `resources:` in `Package.swift` (not
just `ZeroCore`/`pricing.json`), which is exactly what `Bundle.module`'s runtime lookup expects
on macOS (it checks `Bundle.main.resourceURL`, i.e. `Contents/Resources/`). No change needed to
`PricingTable.swift` or `Package.swift` — the resource declaration and the fallback-on-missing-
file guard are both already correct; only the packaging step was missing a copy.

## Files affected
- `Scripts/make-app.sh` — add the resource-bundle copy loop.
- `Scripts/test-app-bundle.sh` — reproduction test (already added, currently failing).

## Risks / side effects
- Low risk: purely additive copy step in a packaging script; doesn't touch app code or the
  build's compiled output.
- If a future target adds a resource bundle whose name happens to end in `Tests.bundle` without
  being a test target, it would be skipped — not the case today, and easy to special-case later
  if it ever happens.

## Rollback
Revert the `Scripts/make-app.sh` change (single self-contained diff). No data or state migration
involved.
