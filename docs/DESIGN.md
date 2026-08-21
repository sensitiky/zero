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

**The floor for secondary text is 70% opacity of the foreground token.** At 70% the contrast is
7.91:1, still AAA. At 55% it drops to 5.10:1 — AA only. Never go below 70%. Every dimmed label in
this app — session summaries, field placeholders, the "unknown" states — uses exactly `Theme.
secondaryOpacity`, not a hand-picked gray.

There is no third color. Status, emphasis and hierarchy are carried by **weight, fill, shape and
position** — never by hue. This is not a stylistic preference; it is what makes the app work for
someone who cannot tell two grays apart, and it is why every "is this the primary action" decision
in this codebase gets answered with a filled shape, not a colored one.

## Typography and shape

System font throughout — no custom typeface. Monospace only where the content is code, a
command, a diff, or a token count: `ToolCallCell`, `DiffView`, the permission card's operation
text, every `.monospacedDigit()` count. Prose is never monospaced.

Corner radius says what kind of thing something is:

- **22pt, continuous** — the composer and its equivalent in `ComposeView`. The one thing you type
  into.
- **14pt** — the permission card. A decision, not a message.
- **6–8pt** — tool call cells, diff blocks, the search field. Content, not chrome.
- **Capsule** — buttons inside the permission card. An action, always.

## The controls that recur

**The circle button.** One filled circle, foreground-on-background, an SF Symbol at 12pt bold
inside. It is the *only* filled circular control in the app, and it always means "send" or "stop."
`ConversationPane.circleButton` and `ComposeView.circleButton` are two copies of the same shape on
purpose — starting a session and continuing one are the same act, and two different controls
would say otherwise.

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
checkmarks. A diff's added and removed lines are told apart by a `+`/`−` marker and a faint tint of
the single foreground token — never red and green.

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

The app is fully keyboard-operable (FR-27): ⌘N for a new session, ⌘⇧] / ⌘⇧[ between sessions, and
every permission option has a single-letter shortcut (`a`/`A`/`d`/`D`) so a permission prompt never
requires reaching for the mouse — the thing most likely to get answered carelessly if it does.

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
