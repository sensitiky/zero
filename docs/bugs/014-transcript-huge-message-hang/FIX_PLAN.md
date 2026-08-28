# Fix Plan — App opens but shows nothing after build

## Branch / worktree
Branch: fix/014-transcript-huge-message-hang
Isolation mode: current checkout branch

## Root cause (one line)
`Markdown.blocks(of:)` (`Sources/ZeroCore/Markdown/Markdown.swift`) has no cap on a block's
length, so a single huge message (247,142 chars, from the `010-provider-handoff` seeded
composer) survives as one uncapped block, and every caller hands it whole to a SwiftUI `Text`;
CoreText then hangs the main thread laying it out, before `RootView`'s first frame ever fires.

## Fix approach
Cap block length **once, in `Markdown.blocks(of:)`** — the one function every transcript render
path (`MarkdownText`/`MarkdownBody`, used by `UserMessage`, the assistant-text case, and
`ThinkingBlock`) already routes through. This is the shared choke point: fixing it here protects
every caller, present and future, instead of adding a guard at each call site.

- Add a `Markdown.maxBlockLength` constant (`20_000` characters — generous for any real
  paragraph or pasted code/diff, far below where CoreText layout gets expensive).
- When a paragraph, heading, or code block's text would exceed that, truncate it to the limit
  and append a plain marker, e.g. `"\n\n… (message truncated, N more characters)"`, computed from
  the actual overflow so it's accurate per block. Truncation happens at block-emission time
  (`flushParagraph()`, and the two `result.append(.code…)` sites, and the heading branch), not by
  post-processing the whole string, so a message with many small blocks is untouched and only the
  one oversized block pays the cost.
- No new UI, no "expand" affordance, no persistence-layer change — the stored message is
  untouched; only what reaches `Text` is capped. That keeps this a bug fix, not a feature.

## Files affected
- `Sources/ZeroCore/Markdown/Markdown.swift` — add the cap in `blocks(of:)`.
- `Tests/ZeroCoreTests/Markdown/MarkdownTests.swift` — reproduction test already added
  (`hugeMessageIsCapped`); will go green once the cap lands. No further test changes planned
  unless the cap's exact behavior (e.g. the truncation marker wording) needs its own case.

## Risks / side effects
- A legitimately long single block (a big pasted log or diff with no blank lines) now gets
  truncated at 20,000 characters instead of rendering in full. Judged an acceptable trade-off: a
  message that size already made the transcript sluggish to scroll, and a hang that blanks the
  whole app is strictly worse than a truncated block. No existing test asserts a block longer
  than 20,000 characters renders in full.
- The one real session already on this machine with the 247,142-character message will render
  that message truncated after the fix — expected and desired; no data migration needed since the
  stored content itself is untouched.

## Rollback
Revert the `Sources/ZeroCore/Markdown/Markdown.swift` change (single function); the reproduction
test would then fail again, same as it does today.

## Implementation note (found while verifying against the live repro)
Capping `Markdown.blocks(of:)` alone was not sufficient. `MarkdownBody`
(`Sources/Zero/Markdown/MarkdownText.swift`) caches its fully-styled, capped blocks in `@State
rendered`, computed asynchronously in `.task(id: text)` — but before that task resolves, `body`'s
synchronous fallback was `rendered ?? [.paragraph(text: AttributedString(text))]`, wrapping the
**raw, uncapped** `text` directly. SwiftUI lays that fallback out on the very first render, before
the async task ever runs — so the original hang happened on that first pass, unreached by the
ZeroCore cap. Fixed by making the fallback go through the same `Markdown.blocks(of:)` split
(cheap — a line split, now capped) instead of wrapping `text` whole, only skipping the inline
markdown *styling* (which stays async) until `.task` resolves. Verified against this machine's
actual poisoned store (the real 247,142-character message): before, `ZERO_MEASURE_STARTUP=1
./build/Zero.app/Contents/MacOS/Zero` never printed and stayed pegged near 100% CPU; after, it
prints `zero: first frame at 1.660s after process start` and the process goes idle.
