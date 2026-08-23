#!/bin/bash
# Reproduction test for docs/bugs/001-dmg-resource-bundle-crash: Zero.app must ship every SwiftPM
# resource bundle it depends on, or Bundle.module fatalErrors at runtime once the binary is copied
# out of .build/ (see PricingTable.bundled() / Bundle.module crash).
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

Scripts/make-app.sh "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Zero.app"
missing=0

for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    name="$(basename "$bundle")"
    # Test-target resource bundles (e.g. Zero_ZeroCoreTests.bundle) aren't a runtime dependency
    # of the shipped app — only bundles for targets Zero actually links against matter here.
    case "$name" in
        *Tests.bundle) continue ;;
    esac
    if [ ! -e "$APP/Contents/Resources/$name" ]; then
        echo "FAIL: $name not found in $APP/Contents/Resources" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    exit 1
fi
echo "OK: all resource bundles present in $APP"
