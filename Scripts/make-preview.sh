#!/bin/bash
# Builds ZeroPreview.app: the same Zero binary, launched with ZERO_PREVIEW=1 so it seeds itself
# with a mock conversation instead of an empty state — every panel populated, for looking at the
# UI without a real repository or agent.
#
# A separate bundle rather than a flag on make-app.sh: the two must never be confused, and a
# distinct name plus a distinct favicon-equivalent (a different bundle id) is what prevents that.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product Zero
swift build -c "$CONFIG" --product zero-permission-hook

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/ZeroPreview.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Zero" "$APP/Contents/MacOS/ZeroPreview"
cp "$BIN/zero-permission-hook" "$APP/Contents/MacOS/zero-permission-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ZeroPreview</string>
    <key>CFBundleIdentifier</key><string>tech.incu.zero.preview</string>
    <key>CFBundleName</key><string>Zero Preview</string>
    <key>CFBundleDisplayName</key><string>Zero Preview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>Zero.icns</string>
    <key>LSEnvironment</key>
    <dict>
        <key>ZERO_PREVIEW</key><string>1</string>
    </dict>
</dict>
</plist>
PLIST

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
fi

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/zero-permission-hook" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "built $APP"
