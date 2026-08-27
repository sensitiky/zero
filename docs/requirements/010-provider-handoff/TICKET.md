# Ticket — Cross-provider conversation handoff on context exhaustion

## Status
Ready

## Problem / outcome
When a session's provider runs out of context mid-conversation, the user has no way to continue
that same conversation on a different provider or model — only to abandon the transcript or
re-explain everything from scratch. This ships a general-purpose "continue this conversation in a
new session" action: it works with any provider/model pair, is available any time, and is
auto-offered the moment a turn ends because the model ran out of context.

## Scope

**In**
- Detect `AgentEvent.turnEnded(.maxTokens)` — currently discarded — and surface it as a state/notice.
- Auto-prompt "Continue with another provider" when that signal fires.
- A manual "Continue in new session…" action, available regardless of the signal.
- New session creation seeded with the source session's `orderedMessages`, target provider/model
  chosen via the existing `ProviderModelPicker`.
- Manual, real, dual-CLI verification on this machine: Claude → Codex and Codex → Claude.

**Out**
- True cross-provider "resume" (not possible — see feasibility).
- Automatic summarization/truncation of the replayed transcript (full-history replay is the
  default for this ticket; truncation strategy is left to the PRD if it turns out to be needed).
- Any change to `rate_limit_event` handling (Claude-specific, a different signal, already surfaced).
- New cost/pricing handling beyond what exists today.

## Feasibility notes
- **Not possible:** literal cross-provider resume. `SessionRuntime.resume` only relaunches Claude
  Code with `--resume <id>` (`Sources/ZeroCore/Session/SessionRuntime.swift:433-447`); Codex/ACP
  have no verified resume flag and fall back read-only. Provider session ids are each provider's
  own opaque backend handle — there is nothing to hand another provider.
- **Possible, minimal new plumbing:**
  - The full transcript already persists locally regardless of provider
    (`Session.orderedMessages`, `Sources/ZeroCore/Persistence/Models.swift`), so a new session can
    be seeded by serializing that history into the `prompt` a fresh `SessionRuntime.create`
    already accepts (`Sources/ZeroCore/Session/SessionRuntime.swift:228-381`) — no new
    provider-facing API needed.
  - The trigger exists but is discarded: `AgentEvent.turnEnded(StopReason)` carries `.maxTokens`
    from all three decoders (`Sources/ZeroCore/Providers/ClaudeCode/ClaudeCodeDecoder.swift`,
    `Codex/CodexDecoder.swift:282`, `ACP/ACPDecoder.swift:308`), but `Transcript.apply` drops the
    reason (`Sources/ZeroCore/Session/Transcript.swift:96-98`).
  - `rate_limit_event` (`ClaudeCodeDecoder.swift:29-36`, surfaced today as a "Rate limited: …"
    notice, `Transcript.swift:89-90`) is a *different*, Claude-only signal (API throttling) — not
    the trigger for this feature.
  - `ProviderModelPicker` (`Sources/Zero/Compose/ProviderModelPicker.swift`) already lets a user
    pick any available provider/model — reusable as-is for picking the handoff target.

## Affected repositories / modules
Single repo (`zero`).

| Repo | Modules touched | Nature of change |
|------|-----------------|-------------------|
| zero | `ZeroCore/Session/Transcript.swift` | code — stop reading `.maxTokens` and drop it |
| zero | `ZeroCore/Session/SessionRuntime.swift` | code — transcript-to-prompt seeding |
| zero | `Zero/SessionCoordinator.swift`, `Zero/AppModel.swift` | code — handoff action, wiring |
| zero | `Zero/Compose/ProviderModelPicker.swift` | reused as-is |
| zero | new UI surface (banner / action) | code — exact location decided in the dev flow's plan |

## Cross-repo dependencies
None (single repo). **Depends on ticket `012-codex-version-check-fails`** for the Codex leg of the
manual dual-provider verification — Codex currently misreports as unavailable. That ticket is
being worked in parallel by another agent; if it hasn't landed by the time you reach validation,
note it as a blocked acceptance criterion rather than working around it by editing the descriptor
yourself (that fix belongs to ticket 012, not this one).

## Acceptance criteria
1. When a turn ends with `StopReason.maxTokens` for any provider, the session surfaces a visible
   prompt offering to continue the conversation with a different provider/model.
2. A manual action to start a new session seeded from the current one's transcript is available
   regardless of whether the limit was hit.
3. The new session is created via the existing `SessionRuntime.create` path, with the source
   session's `orderedMessages` serialized into its opening prompt.
4. The user picks the target provider/model via the existing `ProviderModelPicker` (or an
   equivalent control) before the new session starts.
5. The original session remains intact and readable — it is not deleted or mutated by the handoff.
6. Manually verified end-to-end on this machine: a Claude Code session handed off to Codex, and a
   Codex session handed off to Claude Code, each producing a reply that references content only
   present in the prior transcript.
7. `rate_limit_event` handling is untouched — it continues to surface only its existing notice.

## Risks / assumptions
- **Risk:** replaying a long transcript verbatim as the new provider's opening prompt can itself
  consume a large fraction of that provider's context. **Assumption, accepted for this ticket:**
  full-history replay, editable by the user before sending (same as any composer message);
  truncation/summarization is explicitly deferred.
- Depends on ticket `012` for its Codex-side manual verification step.

## Open questions
None — resolved at Gate 1: general-purpose scope, auto-detect + manual trigger both in scope,
`Theme.accent`-based ring is a separate ticket.

## Suggested flow
incu-way-development
