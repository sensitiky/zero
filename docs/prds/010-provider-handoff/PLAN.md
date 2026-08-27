# Implementation Plan — Cross-provider conversation handoff on context exhaustion

## Branch / worktree
Branch name: `feat/010-provider-handoff`
Isolation mode: separate worktree (`.worktrees/010-provider-handoff`)

## Phases

### Phase A — Signal: stop discarding `.maxTokens`
- [ ] A1. `Transcript`: add a transient `contextExhausted: Bool` (default `false`), alongside the
  existing `pendingPermission` field (`Sources/ZeroCore/Session/Transcript.swift`).
- [ ] A2. In `apply(_:)`, change the `case .turnEnded:` arm to `case .turnEnded(let reason):` and,
  when `reason == .maxTokens`, set `contextExhausted = true` and append
  `.notice(id: UUID(), text: "Context limit reached.")` to `entries` before returning `.idle`. All
  other reasons keep today's behavior exactly (`Sources/ZeroCore/Session/Transcript.swift:96-98`).
  Do not touch the `rateLimit` arm.
- [ ] A3. Add a `resolveContextExhausted()` mutating method that clears the flag (mirrors
  `resolvePermission()`).
- [ ] A4. Unit tests in `Tests/ZeroCoreTests/Session/TranscriptTests.swift`:
  - `.turnEnded(.maxTokens)` sets `contextExhausted` and appends the notice.
  - `.turnEnded(.endTurn)` (and any other non-`.maxTokens` reason already covered by existing
    fixtures) leaves `contextExhausted` false and appends no notice.
  - `.rateLimit` behavior is unchanged (regression guard for FR-2 / AC7).
  - `resolveContextExhausted()` clears the flag.

### Phase B — Surfacing to the UI model
- [ ] B1. `AppModel.SessionSnapshot`: add `var contextExhausted: Bool { transcript.contextExhausted }`
  next to the existing `pendingPermission` computed property (`Sources/Zero/AppModel.swift:60`).
- [ ] B2. `AppModel.appendUserMessage`: also clear the flag
  (`sessions[index].transcript.resolveContextExhausted()`) when a new user message is sent, so
  continuing to chat on the same provider dismisses the offer.
- [ ] B3. `AppModel`: add a `dismissContextExhausted(sessionID:)` method (parallel to
  `resolvePermission(sessionID:)`) for an explicit dismiss action on the card.

### Phase C — Transcript-to-prompt serialization (testable, in ZeroCore)
- [ ] C1. Add a small pure function — e.g. `Session.handoffPrompt() -> String` or a free function
  taking `[Message]` — in `Sources/ZeroCore/Persistence/` (next to `Models.swift`, or a new small
  `HandoffTranscript.swift` if that reads cleaner) that renders `orderedMessages` as
  `"User: …"` / `"Assistant: …"` lines, skipping `role == "system"` rows, in `sequenceNumber`
  order. Lives in `ZeroCore` specifically so it is unit-testable without SwiftUI (`Sources/Zero`
  has no test target today).
- [ ] C2. Unit test: given a small fixed set of `Message` rows out of order, the function emits
  them role-tagged and in `sequenceNumber` order.

### Phase D — `Composer`: seedable initial text
- [ ] D1. Add `var initialText: String = ""` to `Composer` and initialize
  `@State private var draft` from it (`_draft = State(initialValue: initialText)`,
  `Sources/Zero/Compose/Composer.swift:33`). No behavior change for either existing call site
  (`ComposeView`, `ConversationPane.composer`) since both keep the default `""`.

### Phase E — Handoff sheet (new, small view)
- [ ] E1. New file `Sources/Zero/Handoff/HandoffSheet.swift`: takes the source
  `AppModel.SessionSnapshot`, `AppModel`, `SessionCoordinator`; renders `ProviderModelPicker`,
  `WorkspacePicker`, `PermissionModeControl`, and a `Composer` seeded via Phase D's
  `initialText: source.handoffPrompt` (computed via Phase C), with a Start action.
- [ ] E2. Start action calls `coordinator.startSession(repository: source.projectID, provider:
  <picker selection>, model: <picker selection>, prompt: <possibly-edited text>, workspace:
  model.draftWorkspace, permissionMode: <sheet's own PermissionModeControl value, defaulting
  `.ask`>)` — the exact same call `ComposeView.start()` makes. On return, dismiss the sheet (
  `startSession` already sets `model.selection = .session(id)`).
- [ ] E3. No `Theme.accent` anywhere in this file (NFR / lint gate).

### Phase F — Wiring into `ConversationPane`
- [ ] F1. Exhaustion card: in `ConversationPane.body`, when `session.contextExhausted`, show a
  card in the same slot as `PermissionPrompt` (between `TranscriptView` and `modeRow`) offering
  "Continue with another provider" (opens `HandoffSheet`) and a dismiss control (calls
  `model.dismissContextExhausted(sessionID:)`).
- [ ] F2. Manual trigger: add a control to `ConversationPane.modeRow`, next to
  `PermissionModeControl`, that opens `HandoffSheet` for the currently selected session,
  unconditionally (not gated on `contextExhausted`).
- [ ] F3. No `Theme.accent` in any edited region of this file.

### Phase G — Manual dual-provider verification (this ticket's AC6)
- [ ] G1. Build and run the app locally (`swift build` / run via Xcode or `Scripts/`, whichever
  this repo's `run` path is).
- [ ] G2. Start a Claude Code session, drive it into `.maxTokens` (or, if not practically
  reachable by hand, use the manual trigger instead — AC6 only requires the handoff mechanism
  itself to be exercised end-to-end, not that the limit be hit deliberately) and hand off to
  Codex; confirm Codex's reply references content only present in the prior transcript.
- [ ] G3. Symmetric check: Codex session handed off to Claude Code.
- [ ] G4. If ticket `012-codex-version-check-fails` has not landed on `develop` by this point,
  Codex will misreport as unavailable in `ProviderModelPicker`/`isAvailable`. Record G3 (or
  whichever leg needs Codex as the *target*) as a blocked acceptance criterion in `TESTING.md`
  rather than editing the availability check here — that fix belongs to ticket 012.

## Test plan
- **Unit tests (ZeroCore, required — every FR maps to at least one):**
  - FR-1/FR-2: `TranscriptTests` additions from Phase A4.
  - FR-5: `HandoffTranscript`/serialization test from Phase C2.
- **No new SwiftUI/UI test target exists in this repo** (`Sources/Zero` has none today) — FR-3,
  FR-4, FR-6, FR-8 are covered by the manual verification in Phase G plus a visual/manual pass
  confirming the card and sheet render and wire correctly (recorded in `TESTING.md`).
- **Manual validation checklist** (also becomes `TESTING.md` at Gate 3):
  - Non-`.maxTokens` turn end shows no card, no notice.
  - `.maxTokens` turn end shows the card and the notice; sending another message in that session
    dismisses the card.
  - Manual trigger opens the sheet regardless of `contextExhausted`.
  - Handoff sheet: transcript is pre-filled, editable, provider/model picker works, Start creates
    a new session and switches selection to it.
  - Original session unchanged after handoff (still selectable, transcript intact).
  - `rate_limit_event` notice still appears exactly as before (regression check, AC7).
  - Dual-CLI manual runs from Phase G.

## Rollback notes
Entirely additive: one new file (`HandoffSheet.swift`), one new small serialization helper, and
small additive changes to `Transcript`, `AppModel`, `Composer`, `ConversationPane`. No schema
migration, no changes to `SessionRuntime.create`/`resume`, no changes to `rate_limit_event`
handling. Revert is a straight `git revert` of the feature's commits with no data cleanup.
