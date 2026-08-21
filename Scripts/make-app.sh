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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>Zero.icns</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Design/Zero.icns" ]; then
    cp "$ROOT/Design/Zero.icns" "$APP/Contents/Resources/Zero.icns"
fi

# Ad-hoc signature: enough to launch locally. Real distribution needs a Developer ID plus
# notarization, which is G4 and needs credentials this script must not hold.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/zero-permission-hook" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "built $APP"
