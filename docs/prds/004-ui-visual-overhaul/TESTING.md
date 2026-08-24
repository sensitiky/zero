# Testing guide — Rediseño visual (overhaul)

Branch `feat/004-ui-visual-overhaul`. Everything below is verifiable in `ZeroPreview.app`, which is
already built:

```bash
./Scripts/make-preview.sh && open build/ZeroPreview.app
```

No repository, provider CLI or API key is needed. The preview seeds two projects and four sessions
through the real `Transcript.apply` path.

## What is automated, and what is not

| Check | How | Status |
|---|---|---|
| Diff engine | `swift test` — 13 tests in `Tests/ZeroCoreTests/Diff/FileDiffTests.swift` | 220 tests pass, no regressions |
| Design tokens | `Scripts/lint-design-tokens.sh` (wired into `.github/workflows/ci.yml`) | passes |
| Build | `swift build` | clean, no warnings |
| Everything visual | this document | needs you |

The lint is not decorative — it is what keeps FR-1 to FR-4, FR-8 and FR-21 true after this branch
merges. It fails the build on a literal corner radius, a literal measure, a literal surface opacity,
a raw `.animation(`/`withAnimation(`, or `Theme.accent` appearing in a third file. Each of the five
rules was verified by injecting a violation and confirming the build fails.

## Scenarios

### 1. The three elevation levels (FR-6, FR-7)

Select **"Rotate the staging API key"** — the session waiting on permission. It was seeded
specifically so all three levels are on screen at once.

- The window and transcript are the canvas.
- The tool call, the code block and your own message sit on it (`raised`).
- The permission card is over both, with a soft shadow (`floating`).
- The operation text inside the card recedes into it (`sunken`).

**They must read as three distances, not three greys.** If `raised` and `floating` are hard to tell
apart, that is the finding.

### 2. The accent (FR-8, FR-9, FR-10)

`#a16b0e`, measured at 4.09:1 against both `ink` and `paper`.

- It appears in **exactly two places**: the state dot of the waiting session in the sidebar, and the
  border of the permission card. Look for it anywhere else — a button, the usage ring, a link.
- **Then turn the screen greyscale** (System Settings → Accessibility → Display → Color Filters →
  Grayscale). Everything must still be readable: the waiting dot keeps its ring at full foreground
  weight, and the card keeps its shape and shadow. If any information is lost, FR-9 has failed.

### 3. The diff (FR-15 to FR-18)

Expand the **Edit** tool call in the busy session ("Add rate limiting to the webhook handler").

- Old and new are **interleaved**, not old-block-then-new-block.
- Two line-number gutters, advancing independently.
- Two hunks, with `⋯ continues at line 29` between them — the unchanged middle is collapsed.
- Monochrome: `+`/`−` markers and a tint, never red and green, and never the accent.
- A `Write` (no previous text) still shows the whole file, with one gutter. There is no such call in
  the preview; it is covered by tests.

### 4. Tool call runs (FR-14)

The busy session opens with **four consecutive reads**, collapsed to one row: `4 × Read`.

- Expanding it shows the four calls, each with the detail `ToolCallCell` always gave.
- Each call shows a humanized duration (`0.4s`, not `400 ms`) and a status you can read
  (`waiting to run`, not `pending`).
- The small circle left of each name grows empty → half → full with the call's state.

### 5. Rhythm (FR-13)

Scroll the busy session. Gaps should differ by what they separate: a new turn breaks widest, the
agent's own working (tool calls, plans, thinking) sits tight against the text that introduced it.

### 6. Reduced motion (FR-21)

System Settings → Accessibility → Display → **Reduce motion**.

Nine animations must go static or instant: the composer focus ring, the usage arc, the permission
button hover, the transcript autoscroll, the streaming text fade, the tool status mark, the
permission card's arrival, and the diff's staggered line entry. **Nothing should move.**

### 7. Reduced transparency (FR-7)

System Settings → Accessibility → Display → **Reduce transparency**.

The materials become solid fills. The three levels must still be three distinguishable levels — that
is the whole point of the fallback.

### 8. Dynamic Type

Set the largest text size and check nothing clips: the circle button and its glyph, the usage ring
and its 250pt popover, the state dot, the diff gutter, the permission detail, the model field.

### 9. Keyboard (FR-27 of 001)

- ⌘1 / ⌘2 / ⌘3 switch permission mode — **new**, these pills were mouse-only.
- Unchanged: ⌘N, ⌘⇧] / ⌘⇧[, `a`/`A`/`d`/`D` on a permission prompt, ⌘↩ to send, ⌘. to stop.

### 10. Both themes

Everything above, in light and dark.

## Decisions taken during implementation that differ from the plan

Two, both because measuring contradicted the assumption the plan was written on.

**FR-12, the alternate zero — inverted.** The plan said to enable the alternate-zero stylistic set so
`0`/`O` and `1`/`l`/`I` are distinguishable. Probing the font first showed the opposite: the
monospaced system face already ships the **slashed zero as its default**, and the only stylistic set
on offer (type 35, selector 6) is named *"Alternate 0 no slash"* — it removes the slash. `0`, `O`,
`1`, `l` and `I` are already five distinct glyph ids. So the requirement's intent is met by leaving
the glyphs alone, and what shipped is the `Theme.code(_:weight:)` helper that routes all nine code
surfaces through one font. Open question 2's escalation clause was the reason to check first.

**G3, the search that auto-expands a run — no search to hook into.** The plan says a collapsed tool
run must open itself when a search matches inside, so FR-26 of 001 does not regress. There is no
transcript search in this app: the only search filters sessions in the sidebar, and `AppModel` is
explicit that searching a transcript is a different feature with a different UI. The auto-expand is
implemented and wired to a `transcriptSearch` environment value that **nothing currently sets**, so
it is inert today and correct the moment a transcript search exists. Building the search itself was
out of scope. Flagging it rather than quietly dropping the requirement.

## Blocked: the security scans (J4)

**The three scans required before this gate did not run, and nothing here should be read as
"clean".** None of the tooling is present in this environment:

| Required | Result |
|---|---|
| `snyk_code_scan` (MCP) | tool not available |
| `snyk_sca_scan` (MCP) | tool not available |
| `snyk` CLI | not installed |
| `bash run-sonnar.sh` | file does not exist in this repo |
| `sonar-scanner` / `sonar-project.properties` | not installed / absent |

For context on the risk this leaves open, not as a substitute for the scans: this branch adds **no
dependency** (the diff engine uses `CollectionDifference` from the standard library, which is why it
was chosen), and touches no network, persistence, credential or permission-broker code. `Package.swift`
is unmodified. The change is views, one `Theme`, one pure value type in `ZeroCore`, and one shell
script.

**Needs your decision:** install and configure Snyk and SonarQube for this repo, or proceed on the
validation that did run. I have not marked the gate either way.

## Known contrast finding, pre-existing and untouched

Measuring `StateDot` for FR-9 turned up something that predates this branch: in **light mode**, the
`idle` dot measures 1.73:1 against `paper` and `finished` 1.39:1, both under the 3:1 that WCAG 1.4.11
asks for non-text. (Dark mode is fine: 8.09:1 and 5.72:1.) They come from the 0.45 and 0.3 opacities
that have always been there, and dimness is the intended meaning, so changing them is a design
decision rather than a fix — left alone, and recorded here so it is not lost.
