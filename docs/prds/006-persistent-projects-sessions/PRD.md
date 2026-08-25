# PRD — Persistent projects and sessions across app restarts

## Status
Approved (gate 1, 2026-08-25)

## Problem
Quitting and reopening Zero (installed via the `.dmg`) loses every project and session. The
data was never actually gone from disk in the sense of "never written" — `ZeroCore.Persistence`
already has a complete SwiftData schema and a measured `Store` for exactly this — but
`SessionCoordinator.currentStore()` opens it with `Store()`, whose no-container default is an
**in-memory** `ModelConfiguration`. Nothing is ever written to disk, and `AppModel.projects` /
`AppModel.sessions` start empty on every launch with nothing that loads them.

This is a re-opened requirement, not a new one: `docs/prds/001-agent-chat-core/PRD.md` already
states it as **FR-6** ("sessions, messages, tool calls and counters persist locally; reopening
the app restores the list and full history") and **FR-7** (persisted sessions resume via the
provider's mechanism, degrading to read-only history when it doesn't have one). Plan task **C3**
for that PRD — "persist sessions... restore the list and full history on launch" — was left
unchecked; this PRD closes it.

## Goals
- Quitting and relaunching Zero restores every project and every session exactly as they were:
  same list, same order, same transcript content per session.
- The active project/session at quit is reselected on relaunch, when it still exists.
- Data lives in Application Support, keyed by the app's bundle id — survives a `.dmg`
  reinstall/update, never lives inside `Zero.app` itself.
- A session that was live (idle/running/waitingPermission) when the app quit is restored as
  history immediately; reconnecting its provider process happens lazily, only when the user
  opens it — not N subprocess launches on every cold start.

## Non-goals
- Session/project deletion, archiving, or list pruning. Nothing today deletes a session or its
  worktree; this PRD does not add that. Sessions accumulate; that's the existing behavior, just
  now durable.
- Restoring `thinking` blocks. They are not persisted today (`SessionRuntime.persistAndFlush`
  drops `.thinkingDelta` on purpose, "internal; not persisted") and this PRD does not change
  that — a restored transcript shows the same final content a user would read live, not the
  model's discarded scratch reasoning.
- Restoring relaunch-time notices (`Transcript.Entry.notice`, e.g. "switched to read-only").
  Those describe one specific relaunch and are synthesized fresh whenever it happens again; they
  are not part of the conversation's content.
- Cross-device sync, cloud backup, or export/import of the store.
- Syncing while the app is running against changes made by another instance of Zero, or by hand-
  editing the store file. Single running instance, single writer, same as today.
- Recovering a session's underlying OS process across a quit. It's gone regardless of what
  `Session.state` last said — this PRD only decides how that's *shown* and *resumed*, not how to
  keep a `Process` alive past its parent's death.
- A settings/preferences screen. The one piece of UI-only state this adds (last selection) is a
  single stored value, not a new screen.

## User stories
- As a user, I quit Zero mid-conversation and relaunch it; I see the same projects, the same
  sessions under each, and the same conversation I left, without re-adding the repository or
  losing what the agent said.
- As a user, I was looking at a specific session when I quit; relaunching brings me back to it,
  not to an empty state.
- As a user, a session I closed weeks ago still shows its full history when I open it later.
- As a user, if I moved or deleted a repository folder, the sessions that pointed at it still
  show their history — they just can't be resumed or sent to until the folder is back.

## Functional requirements
1. `Store` opens against an on-disk `ModelContainer` by default, located under
   `Application Support/{bundle id}/` (or the platform equivalent `FileManager` resolves at
   runtime) — never inside `Bundle.main.bundleURL`. The in-memory configuration remains
   available and becomes the explicit opt-in tests use, not the default production path.
2. Adding a project (`AppModel.addProject`, today purely in-memory) and creating a session both
   create/reuse a `Repository` row and link the session to it — `Store.createRepository` exists
   but nothing calls it today (`SessionRuntime.create` passes `repository: nil`, "for now"). An
   empty project with zero sessions still needs a row to be restorable at all.
3. Every message the user sends — the initial prompt and every subsequent `send` — is persisted
   as a `Message` with `role: "user"`, the same way assistant text already is. Today only
   assistant output, tool calls, and usage reach `Store`; the user's half of the conversation
   exists only in the live in-memory `Transcript` and does not survive a restart. This FR closes
   that gap as a prerequisite of FR-3, not a separate feature.
4. On launch, before the first frame that shows the sidebar as empty, `AppModel` is populated
   from `Store`: every persisted `Repository` becomes a `Project`, every persisted `Session`
   becomes a `SessionSnapshot` in that project, ordered the same way the sidebar already orders
   things today (`createdAt`, newest project addition order preserved via persisted `createdAt`).
5. Each restored `SessionSnapshot`'s `transcript` is rebuilt from that session's persisted rows —
   `Message` (user and assistant), `ToolCallRecord` (with its edit fields), plan snapshots (new,
   see Data model changes), and `UsageRecord` — replayed in one global chronological order so
   interleaving matches what was live (see Data model changes: `ToolCallRecord` gains the
   sequence number it doesn't have today). The rebuilt `Usage` totals match what a live session
   would have accumulated. A restored session's `pendingPermission` is not resurrected — a
   permission request has no answering process to route a decision to across a restart, and
   asking the user to decide something with no listener isn't a state worth restoring (resolved
   in Open Questions).
6. A restored session's displayed state reflects that no process is attached: `running` and
   `waitingPermission` are shown as **idle**-with-history on restore (not "running" — nothing is
   running), and `error`/`finished` restore as they were persisted, unchanged.
7. Opening a restored session (selecting it) is what triggers reconnection, via the existing
   `SessionRuntime.resume`: a Claude Code session with a `providerSessionId` attempts a live
   resume; anything else (no `providerSessionId`, or a provider without a verified resume flag)
   opens read-only, matching the existing degrade path (`001-agent-chat-core` FR-7). This must
   not happen for every restored session at launch — only for the one(s) the user actually opens.
8. The project/session selected when the app last quit is persisted (outside the SwiftData
   schema — see Data model changes) and restored as `AppModel.selection` on next launch, if that
   project/session still exists in the store. If it doesn't (deleted from disk out from under the
   app — not reachable via any in-app action today, but the store file could be hand-edited),
   selection falls back to nil, same as a first launch.
9. A restored session whose `worktreePath` (or, for a `currentCheckout` session, its
   repository's `path`) no longer resolves on disk is still shown with its full history. Sending
   a message or resuming it is disabled, with an explicit notice explaining why (folder not
   found), rather than silently failing or hiding the session.
10. Every mutation already routed through `Store` keeps working unchanged for a live session —
    this PRD does not change when or how often a running session flushes, only what happens to
    what's already flushed when the app restarts.

## Non-functional requirements
- Launch-time restore does not block the first frame on I/O proportional to transcript size:
  reading a 10k-message session already measures at 1.1ms (`001-agent-chat-core/MEASUREMENTS.md`
  C2), so a straightforward fetch-and-rebuild at launch is expected to stay well within a frame
  budget for realistic session counts; if a pathological case (many large sessions) is found
  during implementation to threaten that, it's called out at the plan/validation gate rather than
  silently deferred.
- No new dependency: SwiftData stays the engine, already gated for this exact access pattern.
- The on-disk store directory is created with the standard per-user permissions `FileManager`
  gives Application Support subdirectories — no broadened permissions, no shared/world-readable
  location.
- Restoring state must not touch the main-actor with parsing or file I/O beyond what `Store`
  already does on `@MainActor` today (see `Store`'s own doc comment on that constraint) — no new
  NFR is introduced here, the existing one just now also covers restore.

## Data model changes
The existing schema (`Repository`, `Session`, `Message`, `ToolCallRecord`,
`PermissionRequestRecord`, `UsageRecord`, `PricingEntry`) covers session/message/tool-call/usage
storage already — reused as-is. Two additive changes close what it's missing for a faithful
restore:

- **`ToolCallRecord.sequenceNumber: Int`** (new field, defaulted like `Session.permissionMode`
  was — a pre-existing row reads as `0`, not a crash or a special case). Its relationship to
  `Message` is unordered today, same problem `Session.orderedMessages`'s doc comment already
  describes for messages; tool calls need the same fix.
- **A new `PlanSnapshotRecord`** (`id`, `session`, `sequenceNumber`, `itemsJSON`, `recordedAt`) —
  mirrors `UsageRecord`'s shape. Plan updates are user-facing checklist content, not scratch, and
  today nothing persists them (`SessionRuntime.persistAndFlush`'s `case .plan: break`).

Ordering across every entry type (user/assistant messages, tool calls, plan snapshots) needs one
shared sequence so restore can interleave them in the order they actually happened — the plan
generalizes `Session.nextMessageSequence` into one counter used by all three, rather than three
counters that can't be compared to each other.

One new piece of state, deliberately **not** a SwiftData model: the last-active
project/session selection. It's a single scalar UI preference with no relations and no history —
modeling it as a `@Model` for one row would be a schema for a value that never varies in shape.
Candidate: `UserDefaults` (not used anywhere in the codebase yet, but it's the platform-native
fit for exactly this: a small, non-relational, per-user preference), storing the selected
project URL or session UUID plus a discriminator. Finalized at the plan gate.

## UI/UX notes
- No new screens. The sidebar and conversation pane render restored data through the same
  `AppModel`/`SessionSnapshot` shapes they already render live data through — a restored session
  looks like any other session that just isn't currently running.
- The "folder not found" notice (FR-7) reuses the existing notice mechanism
  (`Transcript.Entry.notice`, already used for relaunch-degraded-to-read-only) rather than a new
  banner type.
- No loading spinner for the restore itself is expected to be needed given the NFR above, but the
  plan should note if implementation finds otherwise.

## Open questions
Resolved at Gate 1:
- **A `pendingPermission` mid-decision at quit time is dropped on restore, not shown inert.**
  There is no process left to route a decision to, so displaying Allow/Deny controls that can't
  do anything would be a UI lie. The session restores idle, with history up to (but not
  including) that unanswered request; resuming it normally lets the agent re-ask if it still
  needs to. Confirmed as the right call: an inert permission control is worse than none.
- Per-window scoping of the last-selection preference: not applicable today (one `WindowGroup`);
  revisit only if multi-window ships.

## Conflicts / dependencies
- Supersedes/completes `docs/prds/001-agent-chat-core/PLAN.md` task **C3** (currently unchecked)
  and depends on the SwiftData schema and `Store`/`SessionRuntime.resume` that PRD already
  delivered — no changes to either's public shape are anticipated, only new callers.
- No conflict with `005-mobile-remote-bridge`: the bridge reads through `AppModel`/
  `SessionCoordinator` the same way the window does, so restored sessions are visible to it for
  free once `AppModel` is populated at launch — not itself a requirement of this PRD.
