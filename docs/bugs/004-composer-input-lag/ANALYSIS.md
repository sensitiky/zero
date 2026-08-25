# Analysis — Composer input lag with a large draft

## Root cause

Not the text field's editing path. **The composer's draft is re-shaped by CoreText, in full, twice
per display cycle, because the window's minimum size is derived from content.**

`Sources/Zero/ZeroApp.swift:32` puts a minimum size on the root view:

```swift
.frame(minWidth: 900, minHeight: 560)
```

A `_FlexFrameLayout` carrying a `minWidth` cannot answer "how small may I be?" without asking its
child for its ideal size, and that question recurses down to the composer's `TextField`. SwiftUI
answers it through `NSTextFieldCell.cellSizeForBounds:`, which calls
`-[NSAttributedString boundingRectWithSize:options:context:]` → `CTLineCreateWithAttributedString` →
full OpenType shaping of **the entire draft**. No cache survives, because the string just changed.

AppKit asks that question on **every display cycle**, from two separate observers, and the profile
shows both costing about the same:

```
NSDisplayCycleFlush                                       1813  (47% of the main thread)
├─ updateConstraintsIfNeeded → NSHostingView.minSize()     879  (23%)
└─ layoutIfNeeded → _layoutViewTree → _NSViewLayout        934  (24%)
       both ↓
   StackLayout.prioritize / sizeChildrenGenerally…              ← probes the child at several sizes
   _PaddingLayout.sizeThatFits ×8 nested
   PlatformTextFieldAdaptor._overrideSizeThatFits                ← SwiftUI's TextField bridge
   -[NSTextFieldCell cellSizeForBounds:]
   -[NSAttributedString boundingRectWithSize:options:context:]
   CTLineCreateWithAttributedString                              ← shapes the WHOLE draft
```

The hot leaves are pure glyph work — pair kerning and variable-font axis math, not line breaking:

| leaf (top of stack) | samples |
|---|---|
| `OTL::Coverage::SearchFmt2Binary` | 250 |
| `TRunGlue::TGlyph::glyphID` | 175 |
| `TRunGlue::FocusOnIndex` | 162 |
| `PairSet::ValuePair` (GPOS pair kerning) | 130 |
| `OTL::GPOS::ApplyLookupAt` | 111 |
| `ItemVariationStore::…::ComputeScalar` (variable font) | 93 |

**Main thread was busy for 3867 of ~5000 ms — 77% saturated.** That is what the wait cursor reports,
and it is measured on the real `Zero.app`, not a harness.

## Evidence

`sample` on the running app (pid 3510), captured by a CPU-triggered sampler so the profile covers
the stall rather than the moment before it. Full sample retained at `/tmp/zero-lag.txt`.

## Three wrong hypotheses, recorded so they are not re-proposed

Each of these was stated with more confidence than the evidence supported, and each is **wrong**:

1. **"SwiftUI writes the whole `String` binding back on every keystroke."** No. Reading
   `NSTextView.string`, comparing it and assigning it all measure **< 0.001 ms** at 100 000
   characters — copy-on-write and lazy `NSString` bridging mean no `O(n)` copy happens.

2. **"The cost is TextKit re-layout, so an `NSViewRepresentable` over `NSTextView` fixes it."** The
   prototype gave 2.5× in a bare harness, but the real cost is not in the editing path at all — it is
   in *ancestor size negotiation*. Replacing the field without breaking the measurement chain would
   move the cost, not remove it.

3. **"`axis: .vertical` / `lineLimit(1...10)` is the trigger."** Not it: a single-line `TextField`
   over the same binding measured worse.

A fourth thing is worth stating plainly: **every synthetic harness used before the profile
under-reported**, because none of them contained the `NavigationStack` and the content-derived window
minimum that put this on the display-cycle path. A bare field showed 65 ms at 50 000 chars; the real
app was 77% saturated. **Candidate fixes must be measured in `Zero.app`, not in a harness.**

## What was correctly ruled out

- **The transcript is not rebuilt per keystroke.** `draft` is `@State` inside `Composer`, and no
  `TranscriptView` or markdown frame appears anywhere in the hot stack. That ownership comment in
  `Composer.swift` is accurate.
- **`PricingTable.bundled()`** is a `static let` cache and does not appear in the profile. The
  previously-diagnosed pricing-per-render lag is genuinely fixed.
- **Not a regression.** `Composer.swift` is unchanged since `4654da9`, and `ZeroApp.swift:32`
  predates it. Both are original choices that only bite once drafts get long.

## Affected code

| File | Role |
|---|---|
| `Sources/Zero/ZeroApp.swift:32` | `.frame(minWidth: 900, minHeight: 560)` — puts content on the window's min-size path |
| `Sources/Zero/Compose/Composer.swift:36` | the `TextField` whose measurement is `O(draft)` |
| `Sources/Zero/ConversationPane.swift:68` | reply composer |
| `Sources/Zero/Compose/ComposeView.swift:29` | new-session composer |

## Impact

No data loss, no crash, no corruption — the text always arrives. It saturates the main thread of the
app's most-used control while the user does something entirely ordinary: pasting a long prompt.
Both composer call sites are affected, since both are the same component inside the same window.

## Reproduction path

Deterministic and a function of draft length. In the real app: paste a large draft into the composer
and type. Confirmed at 77% main-thread saturation with the wait cursor visible.

Capture with `bash /tmp/catch-lag.sh` — it arms on the process, waits for CPU to cross a threshold,
then samples, so the profile lands on the stall instead of requiring the operator to start a timer
and type simultaneously.

## Tooling not run

Snyk SAST, Snyk SCA and SonarQube were **not** run for this analysis and nothing is reported as
clean. `.claude/rules/security.md` requires them before the review gate; they were unavailable in
this session (no Snyk MCP tool, `snyk` and `sonar-scanner` absent, no `run-sonnar.sh` in this repo) —
the same situation recorded for 005. They are due before this fix's PR, not before its analysis.

---

## Second profile — with rung 1 in the binary (2026-08-25, pid 14683)

Rung 1 (definite `.frame(height:)` from the bounded prefix) is in the running app: `_FrameLayout`
now sits between the `HStack` and the field in every hot chain, where the pre-fix profile went
straight from `_PaddingLayout` to the text-field adaptor.

**It moved the number and did not fix the bug.** Main thread went from **77% → 51%** busy (sampler
armed at 25%, caught 51%). Acceptance is < 30%.

`/tmp/zero-lag.txt`: 3807 main-thread samples ≈ 3.8 s, of which 2531 are idle in `mach_msg`. The
display-cycle observer branch is **1007** samples, and inside it:

| what | samples | share of the 1007 |
|---|---|---|
| `_overrideSizeThatFits` → `NSTextFieldCell cellSizeForBounds:` → `NSAttributedString boundingRectWithSize:` | **765** | **76%** |
| SwiftUI layout traversal itself | ~240 | 24% |

So the draft is still being shaped by CoreText on the display cycle — **seven separate times per
cycle**, ~115–130 samples each.

### Why the definite height did not stop it: it is the *width* being asked for

Every one of those seven sites has the same ancestry, and it is not a height query:

```
StackLayout.…resize(_:proposal:proxy:) / .prioritize(_:proposedSize:)
  LayoutEngineBox.lengthThatFits(_:in:)          ← "how much horizontal length do you need?"
    _FrameLayout.sizeThatFits(in:context:child:)  ← OUR .frame(height:)
      LayoutProxy.size(in:)                       ← forwards the question to the child anyway
        PlatformTextFieldAdaptor._overrideSizeThatFits
          -[NSTextFieldCell cellSizeForBounds:]
            -[NSAttributedString boundingRectWithSize:options:context:]   ← whole draft, again
```

`.frame(height:)` fixes **one** axis. `_FrameLayout` with a free axis still asks the child for its
size, and the `HStack` needs the field's horizontal length to distribute space. The field answers by
measuring all of the text — the height being pinned changes nothing about that.

This is the load-bearing correction to the fix plan's rung 1: **bounding what the height depends on
was necessary but not sufficient, because the height was never the only thing being asked.**

### Rung 2 is confirmed dead — and for a better reason than the harness gave

`NSHostingView.minSize()` is still on the profile (366 samples) and accounts for **363 of the 765**
measurement samples, via `NSHostingView.layout()` → `invalidateSizeConstraintsIfNecessary()`. But it
is **not** produced by `ZeroApp.swift:32`. `NSHostingView` computes its own minimum size to publish
the window's size constraints, whether or not the content carries a `.frame(minWidth:minHeight:)`.
Removing that modifier cannot remove this branch — which is exactly the "zero effect" the harness
measured, now explained rather than just observed. The remaining ~372 samples are the ordinary
`NSHostingView.layout()` pass and ~20 are `updateConstraints`.

Both branches descend through the same `_FrameLayout` into the same field. **There is no ancestor to
fix.**

### What this leaves

SwiftUI asks a leaf for its size at least once per layout pass, and there are two independent passes
per display cycle. So the only durable fix is for **the field's own answer to be O(1) in draft
length**. `TextField` cannot do that: its answer is `NSTextFieldCell.cellSizeForBounds:`, which is
`O(draft)` and not interceptable from SwiftUI.

Ceiling worth stating: any fix that merely *reduces the number of calls* (e.g. hiding the field in an
`overlay`, which does not propagate its child's size) would land around 10–13% busy at 50 000
characters and still be linear in the draft — it moves the cliff out, it does not remove it.
