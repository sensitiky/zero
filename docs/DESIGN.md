# Design — Zero

## The one rule

If it looks like terminal output, it's wrong. That's the entire premise of this app: agent CLIs
talk in NDJSON, and everything else here exists to turn that into something that looks designed
rather than piped through `cat`.

## Palette

Two tokens, taken from the logo — a glyph built from two crescents forming a zero.

| Token | Value | Dark mode | Light mode |
|---|---|---|---|
| `ink` | `#131313` | background | text |
| `paper` | `#f3f3f3` | text | background |

Neither pure black nor pure white appears anywhere. Contrast is 16.74:1 — below the 21:1 of
`#000`/`#fff`, comfortably past the 7:1 WCAG AAA asks for.

**The floor for secondary text is 70% opacity of the foreground token**, except over a focused
sidebar selection, where it rises to 90% (`Theme.selectedSecondaryOpacity`) — 70% of `paper` on that
fill is 3.35:1, and 90% is 4.54:1. On a selected row the summary is already a size smaller, so size
carries the hierarchy and contrast takes priority.

 At 70% the contrast is
7.91:1, still AAA. At 55% it drops to 5.10:1 — AA only. Never go below 70%. Every dimmed label in
this app — session summaries, field placeholders, the "unknown" states — uses exactly `Theme.
secondaryOpacity`, not a hand-picked gray.

### The one accent

There is one hue, and it has one job: **the agent is waiting for you**.

| Token | Value | vs `ink` | vs `paper` |
|---|---|---|---|
| `accent` | `#8b5cf6` | 4.39:1 | 3.82:1 |

The same value in both themes. It never renders text, so the threshold that applies is the 3:1 of
WCAG 1.4.11 for non-text contrast, cleared in both. It is not the balance point — a single color
sitting between two backgrounds 16.74:1 apart maximizes its weaker side at 4.09:1 — but 3.82:1 is
comfortably above the bar. **Whatever this value becomes, both numbers get measured and written
here**; that is the rule, not the hue.

It appears in exactly two places — `StateDot` when a session is waiting on you, and the pending
permission card — and `Scripts/lint-design-tokens.sh` fails the build if a third file references it.

**It is always redundant.** The dot keeps its ring at full foreground weight and the card keeps its
floating shape and shadow, so desaturate the screen and the same information is still there (WCAG
1.4.1). That is the condition on which the accent exists at all.

**A selected row is ours to color, and it took some finding out.** Left alone, the sidebar fills a
selected row with the **system** accent color — the user's choice in System Settings, not a value
from this document: in light mode a saturated blue that puts the row's own text at 4.6:1 and the
accent dot at 1.2:1, in a palette whose whole argument is 16.74:1 and one hue. `.tint()` does not
reach it; the sidebar style takes that color from AppKit rather than from the environment, which was
measured rather than assumed. A `.listRowBackground` does reach it, so `SessionSidebar` paints the
fill with the foreground token and the row **inverts** onto it: content in the background token at
16.74:1, the summary at the ordinary 70% floor, the accent dot back at its own 4.39:1 / 3.82:1
instead of 1.2:1 on blue.

The fill is the foreground token **softened 10% toward the background** — `#292929` on light,
`#dcdcdc` on dark (`Theme.selectionSoftening`). Full `ink` across a row reads as a hole punched in
the window rather than as a selection; it is the one place the foreground token covers an area
instead of drawing on one. A mix rather than an opacity, because the fill's other job is covering
AppKit's highlight, and 10% translucent is 10% of that blue coming through. On it the title measures
13.0:1 in either theme and the summary 7.2:1 light / 6.0:1 dark at the 70% floor.

**Every row gets that background, not only the selected one.** A transparent one on the rest is what
made the blue flash on click: AppKit highlights a row the instant the mouse goes down, while our own
selection state only catches up on the next render, and for that gap nothing covered the highlight.
The unselected fill is the colour the sidebar is already painted with, so it is invisible except in
the one job it does, which is being opaque.

Two more consequences worth writing down. Selection is passed into `SessionRow` explicitly, because
supplying that background is also what makes the platform stop reporting the row as prominent —
`backgroundProminence` then describes a treatment that is no longer on screen, and the row painted
ink drew ink on ink. And the fill keeps full weight when the window loses focus, where AppKit would
fade to gray: one row out of dozens says "this is the session you are in", and that is worth reading
from across the desk.

Everything else is carried by **weight, fill, shape and position** — never by hue. No status, no
primary action, no link, no session state, no ring. This is not a stylistic preference; it is what
makes the app work for someone who cannot tell two colors apart, and it is why every "is this the
primary action" decision in this codebase gets answered with a filled shape, not a colored one.

## Typography and shape

These are **tokens in `Theme`, not conventions to remember.** That distinction is the whole point:
the version of this section that described a radius scale in prose drifted, because the views used
22, 14, 10, 8, 6 and 4 while the document said 22 / 14 / 6-8. `Scripts/lint-design-tokens.sh` fails
the build on a literal radius, measure, surface opacity or animation in `Sources/Zero`, and runs in
CI on every PR.

System font throughout — no custom typeface.

| Token | What it is for |
|---|---|
| `Theme.display(_:)` + `displayTracking` | The two places a screen asks a question and has nothing else on it: the `ComposeView` headline and `EmptyStatePane`. |
| `Theme.code(_:weight:)` | Anything that is code: a path, a command, a diff, a tool name, a model id. |
| `Theme.secondary(_:)` | Every dimmed label, at the 70% floor and never below it. |

**On the mono face.** `Theme.code` uses the monospaced system face at its defaults, and deliberately
does *not* enable the "Alternate 0 no slash" stylistic set (type 35, selector 6). The default face
already ships the slashed zero, and `0`, `O`, `1`, `l` and `I` are already five distinct glyphs; the
alternate set takes the slash *away*. The requirement was to make those characters distinguishable,
and the way to meet it is to leave the glyphs alone and route every code surface through one helper.

Corner radius says what kind of thing something is — `Theme.Radius`:

- **`composer`, 22pt continuous** — the composer and its equivalent in `ComposeView`. The one thing
  you type into.
- **`card`, 14pt** — the permission card. A decision, not a message.
- **`content`, 8pt** — code blocks, diff containers, the user's own message.
- **`inline`, 6pt** — tool call cells, the search field. Chrome around content.
- **Capsule** — buttons inside the permission card, and the permission mode pills. An action, always.

## Elevation

Four named levels in `Theme.Elevation`, and a view picks a level rather than a fill. Above `canvas`
they are drawn with native macOS materials, so a surface picks up what is behind it instead of being
a flat grey rectangle.

| Level | What sits there |
|---|---|
| `canvas` | The window, the sidebar, the transcript. No surface of its own. |
| `sunken` | A well inside another surface: the permission card's operation text. |
| `raised` | The composer, tool call cells, code blocks, diffs, the user's own message, the search field. |
| `floating` | The permission card and the usage popover. Arrived over everything, and holds the interaction. |

Under `accessibilityReduceTransparency` every level falls back to a solid fill picked to keep the
same separation between adjacent levels. Only `floating` casts a shadow, and softly — it says "this
is over what you were reading", not "this is a card in a stack of cards".

## Motion

Nine animations, four durations, and every one of them reports a state change or gives feedback.
Nothing here is decoration and nothing repeats forever.

`Theme.Motion` holds the durations: `feedback` (0.1s, a control you are touching), `value` (0.25s, a
number moving to a new number), `arrival` (0.2s, something appearing), `scroll` (0.15s, the
transcript following the conversation).

**Every animation goes through `.zeroAnimation(_:value:)`**, which honours
`accessibilityReduceMotion` — so respecting it is the default and skipping it takes effort. The lint
rejects a raw `.animation(` or `withAnimation(` anywhere in `Sources/Zero`.

## The controls that recur

**The circle button.** One filled circle, foreground-on-background, an SF Symbol inside, scaling
with Dynamic Type. It is the *only* filled circular control in the app, and it always means "send"
or "stop". It is one component, `CircleButton`, used by both composers — starting a session and
continuing one are the same act, and two different controls would say otherwise. So is the box
around it: `Composer` is one component that owns the draft text, which is also why typing no longer
re-renders the transcript behind it.

**Filled means primary.** A pill button in the permission card is filled only for `.allowOnce` —
the one action worth defaulting to. Every other option, including "Allow Always" and both denials,
is outlined. Nothing about *deny* is styled as dangerous, because there is no red in this palette
and inventing one for a single button would be the first color decision made for the wrong reason.

**The usage ring.** A stroked circle, filled fractionally by context used. No fraction drawn — a
dot instead — when the model's context window is unknown, because a ring claims a denominator and
a wrong or invented one is worse than an honest "we don't know." It sits immediately left of the
send button in both composers: the two things that live at the end of every message are what it
costs and the control that sends it.

**State without color.** `StateDot` in the sidebar uses opacity and a ring, not hue, to distinguish
running / idle / finished / waiting-for-you. `PlanList` uses glyphs (`○ ◐ ●`), not colored
checkmarks. A diff's added and removed lines are told apart by a `+`/`−` marker, a line number on each
side, and a faint tint of the single foreground token — never red and green. `ToolStatusMark` is one
circle that grows from empty to half to full, so pending, running and done are a shape changing
rather than a word being swapped.

## Layout

**A measure, not the window.** Transcript and composer both cap at `820pt` and center. Text
running edge-to-edge on a wide display is most of what makes a chat feel like a log file rather
than a conversation.

**One conversation, one box.** `TranscriptView` renders typed entries — user text, assistant text,
thinking, tool call, plan, notice — never a flattened string. A tool call and the diff it produced
are a distinct shape from prose, because they are a different kind of thing to read.

**No second sidebar.** Per-session accounting used to live in a permanent right-hand column. It
is gone: a ring plus a popover, because a whole column of the window for numbers you glance at
occasionally cost more real estate than the glance was worth.

**Grouped, not one long list.** Sessions in the sidebar are grouped under the project they belong
to, each with a dimmed second line — what it's doing now, not what it was asked an hour ago. A
flat scroll of every session ever started stops being navigable well before it becomes a wall.

## Accessibility

Every interactive control that carries meaning through shape or position also carries it through
an explicit accessibility label — `StateDot`, `PlanList`, `PermissionButton`. A screen reader user
gets the same information a sighted user gets from a dot's ring or a pill's fill, spelled out
rather than inferred.

The app is fully keyboard-operable (FR-27): ⌘N for a new session, ⌘⇧] / ⌘⇧[ between sessions, ⌘1 /
⌘2 / ⌘3 for the Ask / Auto / Bypass permission mode, and every permission option has a single-letter
shortcut (`a`/`A`/`d`/`D`) so a permission prompt never requires reaching for the mouse — the thing
most likely to get answered carelessly if it does. The mode pills use command-digit rather than a
bare letter because the composer holds focus almost all the time, and a bare letter would be typed
into the message instead.

**Dynamic Type.** Every fixed frame in the app is `@ScaledMetric`: the circle button and its glyph,
the usage ring and its popover, the state dot and its ring, the diff's line-number gutter, the tool
status mark, the permission detail, the model field. A control that stays 26pt while the text beside
it doubles is a control you can no longer hit.

**Reduced motion and reduced transparency** are both honoured, and both are enforced rather than
remembered — see Motion and Elevation above.

**Color is never load-bearing**, including the one accent: see Palette.

## Process rule: every UI change updates the preview too

Whenever a change touches anything rendered — a new view, a restyled component, new states for an
existing one — `PreviewData.seed()` gets updated in the same change so `ZeroPreview.app` shows it.
The preview is a dependency of "done," not a follow-up.

If the new surface needs data the mock sessions don't have (a new `AgentEvent` case, a new
`ToolCall` shape, a new panel state), extend `PreviewData` to produce it — still through the real
`Transcript.apply` path, never by hand-assembling a `Transcript`. A preview that silently stops
matching what production renders is worse than no preview, because it keeps looking trustworthy
after it stops being true.

## Verifying the UI without a live agent

`Scripts/make-preview.sh` builds `ZeroPreview.app`: the same binary as `Zero.app`, launched with
`ZERO_PREVIEW=1` set via `LSEnvironment` in its own `Info.plist` — a normal launch of `Zero.app`
never sees that variable. On startup it seeds the sidebar with two projects and four sessions
covering every state (running, idle, waiting-on-you, finished), and the running session's
transcript is built by feeding real `AgentEvent` values through `Transcript.apply` — the exact
path a live session drives, not a hand-built mock that could drift from what production actually
produces.

```bash
./Scripts/make-preview.sh && open build/ZeroPreview.app
```

Use it to check layout, spacing, and every panel at once — the tool call cells, the diff, the
plan, the permission card, the usage ring with real numbers — without a repository, a provider
CLI, or an API key.
