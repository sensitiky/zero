#!/bin/bash
# Fails when a view in Sources/Zero writes a design value as a literal instead of a Theme token.
#
# This exists because the convention already failed once: docs/DESIGN.md documented a radius scale
# of 22 / 14 / 6-8 while the views used 22, 14, 10, 8, 6 and 4, and the 820pt measure was a literal
# repeated at four call sites next to a fifth, undocumented 620. Tokens without enforcement are just
# a convention, and the convention is what drifted.
#
# Sources/Zero only. ZeroCore has no views and no palette.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAILED=0

# check <label> <pattern> <explanation>
#
# Reports every match of an extended regex under Sources/Zero. `# design-token-lint:allow` on the
# line is the documented escape hatch, for the rare value a token would obscure rather than name.
check() {
    local label="$1" pattern="$2" explanation="$3" hits
    hits="$(grep -rEn "$pattern" Sources/Zero --include='*.swift' | grep -v 'design-token-lint:allow' || true)"
    if [ -n "$hits" ]; then
        echo "✗ $label"
        echo "  $explanation"
        echo "$hits" | sed 's/^/    /'
        echo
        FAILED=1
    else
        echo "✓ $label"
    fi
}

check "no literal corner radius" \
    'cornerRadius: *[0-9]' \
    'Use Theme.Radius.composer / .card / .content / .inline, or the .zeroPanel(_:radius:) modifier.'

# `.infinity` and `Theme.measure` are the two legitimate arguments; a number is a third measure
# nobody wrote down.
check "no literal measure" \
    'maxWidth: *[0-9]' \
    'Use Theme.measure / Theme.composeMeasure, or the .zeroMeasure(_:) modifier.'

# A fractional argument to .opacity() is a hand-picked grey. Integer 0 and 1 are allowed: they mean
# off and on, which is a state, not a shade.
check "no literal surface opacity" \
    '\.opacity\([^)]*[0-9]*\.[0-9]' \
    'Use Theme.Fill / Theme.Stroke / Theme.Mark / Theme.Diff, or Theme.secondary(_:).'

# FR-21: every animation honours accessibilityReduceMotion. `.zeroAnimation` is how that happens by
# default, so a raw `.animation(` or `withAnimation(` is an animation that forgot. The one legitimate
# exception is the imperative scroll in TranscriptView, which reads the environment itself and is
# marked with the allow comment.
check "no animation outside .zeroAnimation" \
    '(^|[^o])\.animation\(|withAnimation\(' \
    'Use .zeroAnimation(_:value:) with a Theme.Motion duration so reduced motion is honoured.'

# FR-8 is "one accent, one job (plus one deliberate, documented exception)", and the only thing
# that keeps it true next month is counting. The accent is allowed in StateDot (the waiting
# session), PermissionPrompt (the waiting card), and UsageIndicator (the context-severity ring —
# opacity-graded, always redundant with the arc length, never the sole carrier of meaning), plus
# Theme.swift where it is defined.
ACCENT_FILES="$(grep -rl 'Theme\.accent' Sources/Zero --include='*.swift' | sort || true)"
EXPECTED="Sources/Zero/Permissions/PermissionPrompt.swift
Sources/Zero/Sidebar/StateDot.swift
Sources/Zero/UsageIndicator.swift"
if [ "$ACCENT_FILES" != "$EXPECTED" ]; then
    echo "✗ accent used in exactly three views"
    echo "  Theme.accent means one thing — the agent is waiting for you — plus one documented"
    echo "  exception, the usage ring's severity fill. Anything else needs fill, shape or position"
    echo "  instead."
    echo "  expected:"; echo "$EXPECTED" | sed 's/^/    /'
    echo "  found:"; echo "${ACCENT_FILES:-(none)}" | sed 's/^/    /'
    echo
    FAILED=1
else
    echo "✓ accent used in exactly three views"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Design token lint failed. See docs/DESIGN.md and Sources/Zero/Theme.swift."
    exit 1
fi

echo "Design token lint passed."
