#!/bin/bash
# Assembles Zero.app around the SPM-built binary.
#
# There is no Xcode project on purpose: a .pbxproj is a merge conflict waiting to happen, and SPM
# picks up sources by directory. The cost is that the bundle has to be assembled by hand, which is
# this script.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product Zero
swift build -c "$CONFIG" --product zero-permission-hook

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Zero.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Zero" "$APP/Contents/MacOS/Zero"
# The hook helper ships inside the bundle: the app passes its absolute path to the provider CLI, so
# it has to travel with the app rather than be found on the system.
cp "$BIN/zero-permission-hook" "$APP/Contents/MacOS/zero-permission-hook"

# Targets that declare `resources:` in Package.swift (e.g. ZeroCore's pricing.json) get compiled
# into a sibling *.bundle next to the binary, not embedded in it. Those resources have to travel
# into the app, and they go in Contents/Resources **flattened** — the standard macOS location, which
# is what Bundle.main reads.
#
# Not as a nested *.bundle directory, which is what an earlier fix did
# (docs/bugs/001-dmg-resource-bundle-crash) and which never worked: SwiftPM's generated
# Bundle.module builds its path from Bundle.main.bundleURL, so it looks for the bundle at the .app
# ROOT, not under Contents/Resources — and copying it to the root instead is not an option, because
# any unsealed item in the bundle root makes the app unsignable ("unsealed contents present in the
# bundle root"). See docs/bugs/002-bundle-module-lookup-path.
# Test-target bundles aren't a runtime dependency of the shipped app.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    case "$(basename "$bundle")" in
        *Tests.bundle) continue ;;
    esac
    # The contents, not the directory: PricingTable reads pricing.json via Bundle.main.
    cp -R "$bundle"/* "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Zero</string>
    <key>CFBundleIdentifier</key><string>the.stool.zero</string>
    <key>CFBundleName</key><string>Zero</string>
    <key>CFBundleDisplayName</key><string>Zero</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${ZERO_VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>Zero.icns</string>
</dict>
</plist>
PLIST

# The icon is generated from the source PNG rather than committed as a binary .icns: one file to
# update, and the sizes stay in step with it. An earlier version copied a .icns that was never
# produced, so the app shipped with no icon at all and nothing said so.
ICON_SRC="$ROOT/Design/logo.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$(mktemp -d)/Zero.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Zero.icns"
else
    echo "warning: $ICON_SRC missing — the app will have no icon" >&2
fi

# Ad-hoc signature: enough to launch locally. Real distribution needs a Developer ID plus
# notarization, which is G4 and needs credentials this script must not hold.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/zero-permission-hook" >/dev/null 2>&1 || true
# Not `|| true` on the app itself: signing fails outright if anything unsealable ends up in the
# bundle root, and swallowing that ships an unsigned app with nothing saying so. Fail the build.
codesign --force --sign - --timestamp=none "$APP"

echo "built $APP"
