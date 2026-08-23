#!/bin/bash
# Reproduction test for docs/bugs/002-bundle-module-lookup-path (and 001 before it): the packaged
# Zero.app must be able to load its own bundled resources on a machine that is not this one.
#
# Why this replaces the previous assertion: the old version checked that every SwiftPM resource
# bundle was present in Zero.app/Contents/Resources. That was true, and stayed true, while the
# released app kept crashing — because this toolchain's generated Bundle.module accessor never
# looks there. It checks Bundle.main.bundleURL/<name>.bundle (the .app ROOT) and then a build-time
# absolute path baked into the binary. On the dev machine that baked path exists, so a locally
# built app always works and the old test always passed. Asserting the fix's assumption instead of
# the runtime's requirement is how this bug shipped twice.
#
# So the contract under test is deliberately about *reachability from inside the bundle*, not about
# any one layout: the app must carry pricing.json somewhere it can find without the build directory.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

Scripts/make-app.sh "$CONFIG"

APP="$ROOT/build/Zero.app"

# The two self-contained locations a fix may legitimately use:
#   1. Contents/Resources/pricing.json  — the standard macOS location, readable via Bundle.main.
#   2. Zero.app/Zero_ZeroCore.bundle/   — where the generated accessor's mainPath points.
# (2) is recorded for completeness only: a bundle at the .app root cannot be code signed
# ("unsealed contents present in the bundle root"), so (1) is the only viable one. See ANALYSIS.md.
resource_ok=0
[ -e "$APP/Contents/Resources/pricing.json" ] && resource_ok=1
[ -e "$APP/Zero_ZeroCore.bundle/pricing.json" ] && resource_ok=1

if [ "$resource_ok" -ne 0 ]; then
    echo "OK: $APP carries pricing.json somewhere it can resolve without the build directory"
else
    cat >&2 <<EOF
FAIL: $APP cannot resolve pricing.json without the build directory.

  Checked (both absent):
    $APP/Contents/Resources/pricing.json
    $APP/Zero_ZeroCore.bundle/pricing.json

  Contents/Resources/Zero_ZeroCore.bundle may still be present — that is where the 001 fix put it,
  and this toolchain's Bundle.module never looks there. A local run of this app still works only
  because the build path baked into the binary exists on this machine; on a user's machine
  Bundle.module fatalErrors. See docs/bugs/002-bundle-module-lookup-path/ANALYSIS.md.
EOF
    exit 1
fi

# Signing must survive whatever layout the fix chose. make-app.sh signs with `|| true`, so a
# failure there is silent — checked explicitly here, because the tempting fix for this bug
# (a resource bundle at the .app root) makes the app unsignable and would ship unsigned.
if ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "FAIL: $APP is not validly signed (codesign --verify --strict)" >&2
    codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /' >&2
    exit 1
fi
echo "OK: $APP passes codesign --verify --strict"
