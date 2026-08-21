#!/bin/bash
# Signs and notarizes Zero.app for distribution outside the App Store.
#
# Requires credentials this repository must not contain. Set them in the environment:
#
#   ZERO_SIGNING_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   ZERO_NOTARY_PROFILE     a profile stored with:
#                             xcrun notarytool store-credentials <name> \
#                               --apple-id <id> --team-id <team> --password <app-specific>
#
# Nothing here is verified end to end: it has never been run, because doing so needs an Apple
# Developer account. Treat it as the documented procedure, not as a tested path — and say so rather
# than reporting G4 as done.
set -euo pipefail

: "${ZERO_SIGNING_IDENTITY:?set ZERO_SIGNING_IDENTITY}"
: "${ZERO_NOTARY_PROFILE:?set ZERO_NOTARY_PROFILE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Zero.app"
DMG="$ROOT/build/Zero.dmg"

"$ROOT/Scripts/make-app.sh" release

ENTITLEMENTS="$(mktemp -t zero-entitlements).plist"
# Hardened Runtime is on; App Sandbox is deliberately absent. The app launches provider binaries and
# reads the user's repositories, and the sandbox forbids both — see the PRD's platform NFR.
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><false/>
    <key>com.apple.security.cs.disable-library-validation</key><false/>
</dict>
</plist>
PLIST

# The nested helper is signed first: a bundle is only as signed as its innermost executable.
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$ZERO_SIGNING_IDENTITY" \
    "$APP/Contents/MacOS/zero-permission-hook"

codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$ZERO_SIGNING_IDENTITY" \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$DMG"
hdiutil create -volname Zero -srcfolder "$APP" -ov -format UDZO "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$ZERO_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "notarized $DMG"
