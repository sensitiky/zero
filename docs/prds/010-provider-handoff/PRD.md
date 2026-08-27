# PRD — Cross-provider conversation handoff on context exhaustion

## Status
In Review

## Problem
When a session's provider runs out of context mid-conversation, the user has no way to continue
that same conversation on a different provider or model. Today the signal that this happened —
`AgentEvent.turnEnded(.maxTokens)` — reaches `Transcript.apply` and is silently discarded
(`Sources/ZeroCore/Session/Transcript.swift:96-98`, confirmed: the `case .turnEnded:` arm does not
even bind the associated `StopReason`). The session just goes `.idle`, identical to an ordinary
turn ending — the user sees nothing different from a normal reply and has no path forward except
abandoning the transcript or manually re-explaining the conversation to a fresh session.

## Goals
- Detect a context-exhausted turn end for any provider (Claude, Codex, ACP) and make it visibly
  different from an ordinary turn end.
- Offer, automatically when that happens and manually at any other time, a one-action path to
  continue the same conversation in a brand-new session on a different provider/model.
- Do this with no new provider-facing API and no persistence/schema change — the transcript
  already survives regardless of provider, and the new session goes through the exact same
  creation path every other new session uses.

## Non-goals
- **True cross-provider "resume".** Not possible: `SessionRuntime.resume` only relaunches Claude
  Code with `--resume <id>` (`Sources/ZeroCore/Session/SessionRuntime.swift:433-447`); Codex/ACP
  have no verified resume flag and fall back to `readOnly` (line 440-447). Each provider's session
  id is its own opaque backend handle — there is nothing to hand another provider. This PRD ships
  a **new session seeded with the full transcript**, not a resumed one.
- Automatic summarization or truncation of the replayed transcript. Full-history replay is the
  default; the user can edit the seeded text before sending, same as any composer message.
  Truncation is explicitly deferred.
- Any change to `rate_limit_event` handling. It is Claude-only API throttling, already surfaced
  as a `Transcript.Entry.notice` (`Sources/ZeroCore/Providers/ClaudeCode/ClaudeCodeDecoder.swift:29-36`,
  `Transcript.swift:89-90`) and stays exactly as it is.
- New cost/pricing handling beyond what exists today.
- A schema/database migration. Confirmed in discovery: nothing here needs to survive an app
  restart beyond what already persists (the transcript itself). The "context exhausted" signal is
  transient UI state, consistent with how `SessionState.init(persisted:)` already collapses
  `.running`/`.waitingPermission` back to `.idle` on restore (`SessionState.swift:34-40`) — there
  is no live process to reconnect to either way.

## User stories
- As a user whose Claude Code session hits its context limit mid-task, I want to be offered a way
  to continue on Codex (or another model) without retyping everything, so I want a banner that
  appears right when that happens.
- As a user who anticipates a long task will outgrow the current provider's context, I want a
  manual "continue in a new session" action available at any time, not only after the limit is
  already hit.
- As a user handing off, I want to review and edit what gets sent to the new provider before it
  is sent, because a raw transcript dump may need trimming or a clarifying note.
- As a user, I want my original session left untouched after handoff, so I can still read it (or
  hand it off again, or to a third provider) later.

## Functional requirements

1. **Signal capture.** `Transcript.apply` distinguishes `AgentEvent.turnEnded(.maxTokens)` from
   other stop reasons. On `.maxTokens`, in addition to returning `.idle` as today: (a) append a
   `Transcript.Entry.notice` ("Context limit reached." or similar) to the scrollback — parity with
   how `rateLimit` already leaves a durable record — and (b) set a new transient flag readable by
   the UI (see FR-3). Every other `StopReason` (including plain `.endTurn`) behaves exactly as
   today: no notice, no flag.
2. **`rate_limit_event` untouched.** The existing `case .rateLimit(let status, _) where status !=
   "allowed":` branch and its notice text are not modified by this feature. It is a different,
   Claude-only signal (API throttling, not context exhaustion) and must keep surfacing only its
   existing notice.
3. **Auto-prompt on exhaustion.** When the transient flag from FR-1 is set, the session view shows
   a dismissible, actionable card offering "Continue with another provider" — the same visual
   slot `PermissionPrompt` already occupies (between the transcript and the mode row,
   `Sources/Zero/ConversationPane.swift:16-30`), not a passive transcript entry, since a `.notice`
   row (`Sources/Zero/Transcript/TranscriptView.swift:144-149`) has no room for an action. The flag
   clears when the user sends another message in the same session (mirroring how
   `AppModel.appendUserMessage` already flips state back to `.running`) or dismisses the card.
4. **Manual trigger, always available.** A "Continue in new session…" control is visible whenever
   a session is selected, independent of FR-3's flag. Given there is currently no per-session
   toolbar anywhere in `Sources/Zero`, it is placed in the existing mode row
   (`ConversationPane.modeRow`, next to `PermissionModeControl`) rather than inventing a new
   chrome surface.
5. **Handoff sheet.** Both triggers open the same small view: the source session's
   `orderedMessages` (`Session.orderedMessages`, `Sources/ZeroCore/Persistence/Models.swift:83`)
   serialized into plain, role-tagged text (`User: …` / `Assistant: …`, in `sequenceNumber` order)
   pre-filling an editable text field, plus `ProviderModelPicker` for the target provider/model
   (reused as-is — it only needs the `AppModel`/`SessionCoordinator` bindables it already takes,
   `Sources/Zero/Compose/ProviderModelPicker.swift:8-11`), plus a Start action.
6. **New session creation.** Start calls the existing `SessionCoordinator.startSession(repository:
   provider:model:prompt:workspace:permissionMode:)` (`Sources/Zero/SessionCoordinator.swift:200`)
   with the source session's repository, the picker's chosen provider/model, and the
   (possibly user-edited) serialized transcript as `prompt`. This is the same call every ordinary
   new session already goes through — `SessionRuntime.create` needs no changes for this feature.
7. **Original session integrity.** Handoff never mutates or deletes the source session, its
   transcript, or its persisted `Message` rows. It only reads `orderedMessages`.
8. **Selection.** On successful creation, selection moves to the new session
   (`SessionCoordinator.startSession` already does this — `model.selection = .session(id)`), the
   same behavior every other new session gets.

## Non-functional requirements
- **Design-token compliance.** `Theme.accent` is enforced by `Scripts/lint-design-tokens.sh` to
  appear in exactly `StateDot.swift` and `PermissionPrompt.swift` — any new view added by this
  feature (the exhaustion card, the handoff sheet) must not reference `Theme.accent`. Already
  resolved as an open question at Gate 1 for the PO ticket: an accent-colored ring is explicitly a
  separate ticket.
- **Accessibility.** The exhaustion card and its action get the same accessible-label treatment
  `PermissionPrompt` already gets; the handoff sheet's provider picker keeps the accessibility
  label `ProviderModelPicker` already provides ("Agent and model: …").
- **No new dependency, no new provider API surface.** Everything routes through
  `SessionCoordinator.startSession` → `SessionRuntime.create`, already public and already used by
  `ComposeView`.
- **Performance.** No NFR beyond what `SessionRuntime.create` already bears (sending one prompt
  string) — the size risk (a long transcript consuming a large fraction of the new provider's
  context) is accepted per the ticket's risk section, mitigated only by the text being editable
  before send.

## Data model changes
None. No SwiftData schema change. The "context exhausted" signal is transient, in-memory UI state
on `AppModel.SessionSnapshot` (backed by `Transcript`, mirroring how `pendingPermission` already
works), not a persisted column — consistent with the existing restore behavior that already
collapses live-process states back to `.idle` on relaunch.

## UI/UX notes
- Exhaustion card: same slot and card treatment as `PermissionPrompt`
  (`Sources/Zero/ConversationPane.swift:17-30`), offering "Continue with another provider" and a
  dismiss action. No new accent color.
- Manual action: a control in `ConversationPane.modeRow`, next to `PermissionModeControl`.
- Handoff sheet: reuses `ProviderModelPicker`, `WorkspacePicker`, `PermissionModeControl`, and the
  `Composer` component seeded with the serialized transcript as its initial text (`Composer`
  currently owns `@State private var draft = ""` with no seed parameter —
  `Sources/Zero/Compose/Composer.swift:33` — so a small additive `initialText` parameter is needed;
  this is the one net-new piece of plumbing beyond wiring, and is called out explicitly here so the
  plan doesn't have to rediscover it).

## Open questions
None outstanding. Resolved during discovery:
- Exact serialization format for the seeded prompt (role-tagged plain text, `User:`/`Assistant:`,
  in `sequenceNumber` order) — settled above (FR-5) rather than left to implementation guesswork.
- Exact placement of the manual trigger (mode row, since no toolbar exists anywhere in the app
  today) — settled above (FR-4).
- Whether a persisted flag is needed for "context exhausted" — settled above (Data model changes):
  no, transient UI state only.

## Conflicts / dependencies
- No conflicts found with existing PRDs (`docs/prds/001` through `007`) — none touch
  `Transcript.apply`'s `turnEnded` arm, `SessionRuntime.create`, or `ProviderModelPicker`.
- **Depends on ticket `012-codex-version-check-fails`** (being worked in a separate worktree,
  `.worktrees/012-codex-version-check-fails`, branch `fix/012-codex-version-check-fails`, in
  parallel) for the Codex leg of manual dual-provider verification (AC6) — Codex currently
  misreports as unavailable. If unresolved by validation time, that half of AC6 is recorded as a
  blocked acceptance criterion, not worked around here.
