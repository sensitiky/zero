# Bug — Composer goes laggy and shows the wait cursor with a large draft

## Status
Analyzing

## Description
Pasting or typing a large amount of text into the composer makes it progressively unresponsive.
Reported as "the chat box becomes laggy and the charging pointer appears" — the macOS wait cursor,
which the window server shows when the main thread stops servicing events.

The paste itself is not the problem. **Every keystroke after it is**, and its cost grows with how
much text is already in the box.

## Steps to reproduce
1. Open a session (or the compose screen — both use the same `Composer`).
2. Paste a large block of text into the field. Something on the order of tens of thousands of
   characters: a long log, a file, a spec.
3. Keep typing at the end of it.
4. Each keystroke lands late; the field stops keeping up with the keyboard and the pointer turns
   into the wait cursor.

## Expected behavior
Typing stays responsive regardless of how much text is in the draft. A keystroke should cost roughly
the same whether the box holds 100 characters or 100 000.

## Actual behavior
Per-keystroke main-thread work is **linear in the length of the draft**. Measured on this machine
(Apple silicon, macOS 26) against a live, focused, editing field — best of 6 insertions, so these
are floors, not outliers:

| chars in the field | keystroke cost, `Composer` today |
|---|---|
| 1 000 | 3.6 ms |
| 5 000 | 12.6 ms |
| 20 000 | 26 ms |
| 50 000 | 66 ms |
| 100 000 | 100–127 ms |

At 20 000 characters the field can no longer hold 60 fps while you type. Past ~50 000 each keystroke
blocks the main thread long enough that keystrokes queue behind one another, and a saturated main
thread is exactly what produces the wait cursor.

A single large paste, by contrast, costs 45–60 ms once — noticeable, but not the complaint.

## Context
- Environment: local, `build/Zero.app` (debug), Apple silicon, macOS 26
- Affected commit / version: `develop` @ `bd7ba95`; the code predates it — `Composer.swift` has not
  changed since `4654da9` (004-ui-visual-overhaul)
- Affected code: `Sources/Zero/Compose/Composer.swift:36`
- Affected users: anyone pasting a long prompt. **Both** composer call sites, since they share the
  component: `ConversationPane.swift:68` (reply) and `ComposeView.swift:29` (new session)
- Severity: Medium — no data loss, no crash, but it degrades the app's single most-used control, and
  pasting a long prompt into an agent is an ordinary thing to do
- Not a regression: no commit introduced this. It is the cost of the original implementation
  choice, surfacing once drafts got large enough

## Logs / stack trace
None — the app does not crash and logs nothing. The evidence is timing, above and in ANALYSIS.md.
