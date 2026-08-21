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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Zero</string>
    <key>CFBundleIdentifier</key><string>tech.incu.zero</string>
    <key>CFBundleName</key><string>Zero</string>
    <key>CFBundleDisplayName</key><string>Zero</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${ZERO_VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
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
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "built $APP"
