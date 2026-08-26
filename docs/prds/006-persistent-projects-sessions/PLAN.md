# Implementation Plan — Persistent projects and sessions across app restarts

## Branch / worktree
Branch name: `feat/006-persistent-projects-sessions`
Isolation mode: current checkout branch

## Design decisions (settled here, not re-litigated per task)

- **`Store(modelContainer: nil)` stays in-memory, unchanged.** ~20 existing call sites (mostly
  tests) rely on that meaning today. Rather than flip the meaning of "no container" — which would
  silently move every one of them onto disk — production gets a new, explicit factory:
  `Store.defaultModelContainer(baseDirectory:) throws -> ModelContainer`, resolving
  `Application Support/{bundle id}/Zero.store` (bundle id via `Bundle.main.bundleIdentifier`,
  falling back to `"the.stool.zero"`), creating the directory if missing.
  `SessionCoordinator.currentStore()` becomes the one production call site that uses it. The
  `baseDirectory` parameter (defaulting to the real Application Support URL) is the seam
  `StoreTests` uses to point at a temp directory instead of touching the real one.
- **One shared sequence counter, not three.** `Session.nextMessageSequence` generalizes to
  `nextEntrySequence`, used by `Message`, the new `ToolCallRecord.sequenceNumber`, and the new
  `PlanSnapshotRecord.sequenceNumber` — because restore has to interleave all three into one flat
  `Transcript.entries` array in the order they actually happened, and three independent counters
  can't be compared. `nextUsageSequence` stays separate: usage isn't a `Transcript.Entry`, it only
  ever feeds `Usage` totals.
- **`workspace` is derived, not stored.** `SessionRuntime.Workspace` has no persisted field today
  and doesn't need one: `.currentCheckout` iff `session.worktreePath == session.repository?.path`,
  else `.isolatedWorktree`. Matches how the live path already sets `worktreePath = repository` for
  `.currentCheckout`.
- **No SwiftData migration plan.** `Store()`'s no-container default has only ever been in-memory
  — no installed build has ever written this schema to disk. Adding a field and a model type today
  has no existing on-disk data to migrate. The next schema change after this one ships is the
  first that needs a real migration story.

## Known limitations (call these out at Gate 3, not discovered there)

- **Text split around an inline tool call collapses on restore.** Live, `"draft"` → `toolCall(A)`
  → `" done."` renders as three separate entries (text, tool, text). Persisted, both text deltas
  land in the *same* `Message.content` (`SessionRuntime.persistAndFlush` appends to
  `pendingMessage` across a tool call, by design — one row per open message). Restore reproduces
  the tool call in the right position relative to other entries, but the surrounding text as one
  merged block, not split around it. Pre-existing storage granularity, not introduced by this
  plan; fixing it means changing how a turn's text is chunked into rows, a different-shaped change
  than "make what's already written durable." Out of scope here.
- **`Usage.costUSD` and `.thinkingTokens` don't round-trip.** `UsageRecord` never stored them (no
  column for either). A restored session's usage falls back to the price-table computation for
  cost, same as it does today whenever a provider doesn't report a cost itself. Adding the columns
  is a one-line schema change if this turns out to matter; not requested, not adding it
  speculatively.

## Phases

### Phase A — Schema: what's missing to interleave and store everything

- [ ] **A1** `Sources/ZeroCore/Persistence/Models.swift`: add `ToolCallRecord.sequenceNumber: Int
      = 0` (defaulted like `Session.permissionMode` — an old row just reads `0`). Add
      `PlanSnapshotRecord` (`id: UUID`, `session: Session?`, `sequenceNumber: Int`, `itemsJSON:
      String`, `recordedAt: Date`), cascade-deleted from `Session` like the other child records.
      Rename `Session.nextMessageSequence` → `nextEntrySequence`; add
      `Session.orderedToolCalls`/`orderedPlanSnapshots` computed properties alongside the existing
      `orderedMessages`/`orderedUsageRecords` (same "SwiftData relationships are unordered"
      reasoning already documented there). (PRD: Data model changes)
- [ ] **A2** `Sources/ZeroCore/Persistence/Store.swift`: factor the `Schema([...])` list used by
      the in-memory branch into a shared `Store.schema` static, add `PlanSnapshotRecord` to it.
      `appendMessage`/`appendToolCall` draw their sequence number from
      `session.nextEntrySequence`; add `appendPlanSnapshot(to:items:)` (JSON-encodes `[PlanItem]`
      the same way `createPermissionRequest` JSON-encodes options). Add
      `upsertRepository(path:name:defaultBranch:) throws -> Repository` (find-by-path-or-create,
      same shape as the existing `setPricingEntry` upsert) and `listRepositories() throws ->
      [Repository]`.
- [ ] **A3** `Store.defaultModelContainer(baseDirectory: URL = Self.applicationSupportURL) throws
      -> ModelContainer` — resolves/creates `{baseDirectory}/{bundle id}/Zero.store`, builds a
      non-in-memory `ModelConfiguration` against `Store.schema`. `SessionCoordinator.currentStore()`
      changes from `try Store()` to `try Store(modelContainer: Store.defaultModelContainer())`.
      (FR-1)
- [ ] **A4** `Sources/ZeroCore/Session/SessionState.swift`: add `init(persisted: String,
      errorMessage: String?)`, mirroring `PermissionMode.init(persisted:)` — unknown/garbage
      string falls back to `.idle` rather than crashing or throwing.

### Phase B — Capture what today silently drops

- [ ] **B1** `Sources/Zero/SessionCoordinator.swift`: `startSession` persists the initial prompt
      as `role: "user"` right after `store.createSession`; `send(_:to:)` persists every subsequent
      user message the same way, before/alongside the existing `model.appendUserMessage` call.
      (FR-3)
- [ ] **B2** `Sources/ZeroCore/Session/SessionRuntime.swift`, `persistAndFlush`: `case
      .plan(let items):` calls `store.appendPlanSnapshot(to: session, items: items)` instead of
      `break`. (Data model changes)
- [ ] **B3** Repository creation, two call sites:
      - `SessionRuntime.create` resolves/upserts the `Repository` row via
        `store.upsertRepository(path: config.repository.path, name: ..., defaultBranch: ...)`
        right before `store.createSession`, and passes it as `repository:` instead of `nil`.
        `defaultBranch` comes from `gitService?.resolveBaseBranch()` regardless of `workspace`
        (for `.isolatedWorktree`, `branchName` at that point is the *new* worktree branch, not the
        repo's default — the wrong value for this field).
      - `Sources/Zero/SessionCoordinator.swift` gains `addProject(_ url: URL)`, calling the same
        `upsertRepository` then updating `model.projects`/`model.selection` the way
        `AppModel.addProject` does today. `Sources/Zero/Sidebar/SidebarHeader.swift`'s one call
        site (`model.addProject(url)`) becomes `coordinator.addProject(url)`. `AppModel.addProject`
        itself can stay (used by the coordinator, and by restore in Phase C) or be inlined —
        decide inline during implementation, not a design question.
      (FR-2)

### Phase C — Restore on launch

- [ ] **C1** `Sources/ZeroCore/Session/Transcript.swift` (or a new `Transcript+Restore.swift`
      beside it): `public static func restoring(_ session: Session) -> Transcript` —
      merge-sorts `orderedMessages` (skipping empty-content assistant rows: those exist only to
      anchor a tool call, never rendered as their own entry live either),
      `session.orderedToolCalls`, `session.orderedPlanSnapshots` by `sequenceNumber` into
      `entries`, mapping each row to its `Transcript.Entry` case (`ToolCallRecord` → `ToolCall` +
      `FileEdit` when `editPath != nil`; `PlanSnapshotRecord.itemsJSON` → `[PlanItem]`). Folds
      `session.orderedUsageRecords` into `usage` via the same merge rule `Transcript.apply`'s
      `.usage` case already uses. `pendingPermission` stays nil (PRD FR-5 / resolved open
      question). Pure and synchronous — testable directly against an in-memory `Store` fixture,
      same pattern `StoreTests` already uses. (FR-5)
- [ ] **C2** `Sources/Zero/SessionCoordinator.swift`: `restoreFromStore()` — `store.listRepositories()`
      → `AppModel.Project` per row; `store.listSessions()` → one `SessionSnapshot` per row, with
      `transcript = .restoring(session)`, `state` from `SessionState(persisted:errorMessage:)`
      collapsed per FR-6 (`.running`/`.waitingPermission` → `.idle`; `.error`/`.finished`
      unchanged), `permissionMode` from the existing `PermissionMode(persisted:)`, `workspace`
      derived per the design decision above. Populates `model.projects`/`model.sessions` in one
      pass before the first frame renders — called from `SessionCoordinator.init` or immediately
      after, not deferred to `.onAppear` (`RootView`'s `.onAppear` already marks first-frame via
      `StartupClock`; restore must be done before that, not racing it). (FR-4, FR-6)
- [ ] **C3** `Sources/Zero/LastSelection.swift` (new, tiny): `UserDefaults`-backed read/write of
      the last `AppModel.Selection` (kind discriminator + id string — no new dependency, stdlib
      covers a two-key preference). `AppModel.selection`'s setter persists on change;
      `restoreFromStore()` sets `model.selection` from it at the end, only if that project/session
      id still exists in what was just restored — otherwise nil, same as a first launch. (FR-8)

### Phase D — Lazy resume + missing-path handling

- [ ] **D1** Opening a restored session (`AppModel.selection = .session(id)` transitioning from
      not-selected, or the sidebar's session-tap handler) is where `SessionCoordinator` calls
      `SessionRuntime.resume` for a session with no live entry in `runtimes[id]` yet — not at
      restore time. Exact hook point (selection `didSet` vs. an explicit "open" call from the
      sidebar) decided during implementation against how `SessionSidebar`/`ConversationPane`
      already trigger session activity; no schema or PRD impact either way. (FR-7)
- [ ] **D2** `AppModel.SessionSnapshot` gains `worktreePath: String` (already known at creation
      time in `SessionCoordinator.startSession`, and at restore time from `Session.worktreePath`)
      so a missing-folder check has something concrete to check against
      (`FileManager.default.fileExists(atPath:)`). A session showing as selected with a missing
      path gets one `.notice` entry (not persisted — matches the existing non-persisted relaunch
      notices) explaining why, and `Composer`'s `canSubmit` gating picks up the same check so
      sending is disabled rather than failing silently. (FR-9)

## Test plan

- **Unit tests** (`Tests/ZeroCoreTests/Persistence/StoreTests.swift`, extended):
  - `defaultModelContainer(baseDirectory:)` resolves under the given base + bundle id, not under
    `Bundle.main.bundleURL`.
  - Durability: open a `Store` against a temp `baseDirectory`, write a repository/session/full
    history, drop the `Store`, open a **second** `Store` against the same `baseDirectory`, read it
    back unchanged. This is the regression test for the actual bug.
  - `upsertRepository` called twice with the same path returns the same row, not a duplicate.
  - `appendPlanSnapshot` + `Session.orderedPlanSnapshots` round-trip in sequence order.
  - Shared sequencing: interleaved `appendMessage`/`appendToolCall`/`appendPlanSnapshot` calls
    produce a single, gapless, chronological `sequenceNumber` order across all three.
- **Unit tests** (new `Tests/ZeroCoreTests/Session/TranscriptRestoreTests.swift`): build a
  `Store` fixture with interleaved user/assistant messages, a tool call with a `FileEdit`, a plan
  snapshot, and usage records; assert `Transcript.restoring(_:)` reproduces the same `entries`
  order and content, and the same final `usage`, a live session would have; assert an
  empty-content assistant row (tool-call anchor only) produces no `.assistantText` entry; assert
  `pendingPermission` is always nil regardless of persisted `PermissionRequestRecord` rows.
  Also: `SessionState.init(persisted:errorMessage:)` round-trips all five states plus an unknown
  string falling back to `.idle`.
- **Manual validation** (`Zero` executable target has no test target — matches the existing
  project convention of manual checks for the UI/coordinator layer, see `TESTING.md`):
  1. Add a project, start a session, send a few messages, let the agent make a tool call and
     produce a plan. Quit Zero (`Cmd-Q`), reopen. Same project, same session, same transcript,
     same selection.
  2. Repeat with two projects and several sessions each; confirm grouping/order survives.
  3. Quit mid-turn (session `running` or `waitingPermission`). Reopen: session shows idle with
     history up to that point, no stale "running" spinner, no inert permission control.
  4. Select a restored Claude Code session with a `providerSessionId`: it resumes live. Select one
     without: it opens read-only, same message the live degrade path already shows.
  5. Move/rename a session's project folder, reopen Zero, open that session: history is there,
     sending is disabled with the "folder not found" notice.
  6. Reinstall via a freshly built `.dmg` (`Scripts/make-app.sh` + reinstall) over an existing
     install with data: projects/sessions from before the reinstall are still there.

## Rollback notes
Additive schema (new field with a default, new model, renamed-but-equivalent counter field) and
one new production call site (`Store.defaultModelContainer`) behind an otherwise-unchanged `Store`
API. Reverting this branch reverts to today's behavior (in-memory `Store`, no restore) with no
on-disk artifact to clean up for any existing user, since no build has ever written this schema to
disk before. No feature flag needed.
