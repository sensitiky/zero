---
name: incu-way-development
version: 0.1.0
description: Use for product feature work that explicitly needs discovery, a PRD, gated implementation planning, or stakeholder approval before code changes. Trigger for ambiguous, cross-cutting, client-requested, or high-risk functionality changes. Do not trigger for small direct code edits, routine refactors, bug fixes, security scans, documentation-only work, or questions about existing code.
---

# Development Process

A structured, gate-driven workflow for shipping new features without guessing. Start with discovery and intake, then move through PRD, planning, implementation, validation, and PRs with explicit user approval at each critical gate.

---

## Phase 0 — Discovery and Intake (before anything)

Before writing a single line of code or project docs, gather enough product and codebase context to avoid drafting the wrong PRD.

### Discovery checklist

1. Read `PRD.md` (project root).
2. Read all existing docs in `docs/` and all PRDs in `docs/prds/`.
   If a refined ticket exists for this request at `docs/requirements/{slug}/TICKET.md`
   (produced by `incu-way-po`), read it first: treat its acceptance criteria as the
   PRD's starting functional requirements, and verify — rather than re-derive — its
   feasibility notes and affected-module map.
3. Clarify the request in product terms:
   - what change is being requested
   - who it is for
   - what the client or stakeholder is expecting
   - what success looks like
   - what constraints or non-goals already exist
4. Discover the codebase context:
   - current behavior related to the request
   - likely affected modules, entry points, integrations, and tests
   - existing patterns that should be preserved
   - conflicts, overlaps, or dependencies with existing functionality
5. Scale the depth of discovery to the request:
   - for small, well-specified changes, keep the pass lightweight
   - for ambiguous, cross-cutting, or client-sensitive requests, dig deeper before drafting anything
6. If critical unknowns remain, ask focused clarifying questions before moving on to the PRD.

### Phase 0 exit criteria

Before Phase 1, Claude should be able to state:
- the problem being solved and the requested change
- who the change is for and what the client/stakeholder expects
- the success criteria or definition of done known so far
- which docs, modules, flows, or integrations are likely affected
- which assumptions are being made
- which open questions still need user input

If Claude cannot answer those points with reasonable confidence, do not draft the PRD yet. Ask clarifying questions first.

---

## Isolation setup (immediately after Phase 0)

**Before writing any file**, ask the user how they want to isolate the work:

> Do you want me to work in a new branch in the current checkout, or create a separate git worktree?

Use the user's answer exactly:
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branches or creating a worktree.

### Option A — Branch in current checkout

```bash
# Run from the repo root
git switch develop
git pull --ff-only
git switch -c feat/{slug}
```

All subsequent work — PRD, plan, code, docs, commits — happens on this branch in the current checkout. Never write files to `develop` or `main` directly.

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/{slug} -b feat/{slug} origin/develop
```

All subsequent work — PRD, plan, code, docs, commits — happens exclusively inside this worktree. Never write files to `develop` or `main` directly.

---

## State tracking — `.ways/state.json`

Follow the **ways/v1alpha1 state contract** — the canonical `.ways/state.json` format (`schemaVersion` 2), shipped as the **always-on `state-contract` rule** that `ways add` places into the project, so it is already in your context (no path to follow). Its source in this repo, for maintainers, is `ways/rulepacks/state-contract/`. Do not copy or invent a schema in this skill.

Flow-specific values:
- `flow`: `feature`
- `way`: `incu/dev` · `discipline`: `development` (optionally `wayVersion` from the way manifest)
- Branch pattern: `feat/{slug}`
- Initial `phase`: `discovery`
- `isolationType`: `branch` or `worktree`, from the isolation choice in Phase 0
- Documents: `docs/prds/{slug}/PRD.md`, `docs/prds/{slug}/PLAN.md`, `docs/prds/{slug}/TESTING.md`
- Gates: `prd`, `plan`, `testing`, `pr-develop`, `pr-main`

At session start, read `.ways/state.json` if it exists. If its `branch` matches the current `feat/{slug}` branch, report the current phase/next step/pending gates and resume from that state. If it does not exist, or it exists but its `branch` does not match (a stale file inherited from a merged feature), start at Phase 0 and create/overwrite it at `.ways/state.json` right after the selected isolation setup. On each transition also update `lastPhase` (the phase you're leaving).

**Update points (phase → what to write):**

| When | `phase` | Documents / gates / steps |
|------|---------|---------------------------|
| PRD drafted | `prd` | `PRD.md` → `in-review` |
| **Gate 1 passed** | `plan` | `PRD.md` → `approved`; gate `prd` → `passed` |
| Plan drafted | `plan` | `PLAN.md` → `in-review` |
| **Gate 2 passed** | `implementation` | `PLAN.md` → `approved`; gate `plan` → `passed`; **generate `steps` from the PLAN.md tasks — one entry per actionable task, all `todo`** |
| During implementation | `implementation` | mark each step `in-progress` → `done` (or `blocked`) — write the state file **per step, immediately**, never batched at the end of the phase |
| Validation | `validation` | `TESTING.md` → `approved` once written |
| **Gate 3 passed** | `review` | gate `testing` → `passed` |
| PR feat→develop opened | `pr-develop` | gate `pr-develop` → still `pending`; set its `url` to the PR link |
| PR merged to develop | `pr-develop` | gate `pr-develop` → `passed` |
| PR develop→main opened | `pr-main` | gate `pr-main` → still `pending`; set its `url` to the PR link |
| PR merged to main | `done` | gate `pr-main` → `passed` |

The `steps` array generated at Gate 2 is what the board shows as progress (e.g. `3/7`). Step ids can mirror the plan's phase labels (`A1`, `A2`, `B1`, …).

Do not commit `.ways/state.json` yourself — only write it. When the user wants to persist a checkpoint, suggest invoking `incu-way-prepare-pr`, which commits it together with the docs/code of that transition.

---

## Phase 1 — Draft PRD

**Goal:** Produce a focused PRD for the new feature based on the discovery work from Phase 0.

### Where to save

```
docs/prds/{prd-slug}/PRD.md
```

**Slug format:** `{zero-padded-id}-{kebab-feature-name}`
Example: `003-contact-export`, `007-auto-tagging-rules`

IDs are sequential across `docs/prds/` **and** `docs/requirements/` — check both to find
the next ID. If this feature comes from an `incu-way-po` ticket, reuse the ticket's slug
so `docs/requirements/{slug}/` and `docs/prds/{slug}/` line up.

### PRD structure

```markdown
# PRD — {Feature Name}

## Status
Draft | In Review | Approved | In Progress | Done

## Problem
One paragraph. What pain does this solve? Who feels it?

## Goals
Bulleted list. Measurable outcomes where possible.

## Non-goals
What is explicitly out of scope.

## User stories
- As a [role], I want [action] so that [benefit].

## Functional requirements
Numbered list. Concrete, testable.

## Non-functional requirements
Performance, security, accessibility constraints.

## Data model changes
Tables, columns, or relations added/modified. Reference `docs/database-schema.md`.

## UI/UX notes
Key screens or flows. Link wireframes if any.

## Open questions
Unresolved decisions that need user input before implementation.

## Conflicts / dependencies
List any conflicts with existing PRDs or features found in Phase 0.
```

### Gate 1 — PRD review

After writing the PRD:
- Make sure unresolved assumptions and open questions are explicit instead of guessed.
- Surface any open questions explicitly.
- Say: **"PRD draft ready at `docs/prds/{slug}/PRD.md`. Please review before I continue."**
- **Stop. Do not proceed until the user says OK.**

---

## Phase 2 — Implementation Plan

**Goal:** Produce a step-by-step plan that maps PRD requirements to code changes.

### Where to save

```
docs/prds/{prd-slug}/PLAN.md
```

### Plan structure

```markdown
# Implementation Plan — {Feature Name}

## Branch / worktree
Branch name: `feat/{slug}`
Isolation mode: current checkout branch | separate worktree

## Phases

### Phase A — {name}
- [ ] Task 1 (file/module affected)
- [ ] Task 2

### Phase B — {name}
...

## Test plan
- Unit tests: what to cover
- E2E tests: critical paths
- Manual validation checklist

## Rollback notes
How to revert if something goes wrong.
```

### Gate 2 — Plan review

After writing the plan:
- Do not treat unstated assumptions as approved requirements. If key acceptance criteria are still ambiguous, fix the PRD first.
- Say: **"Implementation plan ready at `docs/prds/{slug}/PLAN.md`. Please review before I start coding."**
- **Stop. Do not proceed until the user says OK.**

---

## Phase 3 — Implementation

**Goal:** Implement the feature in the isolated branch or worktree selected by the user.

### Setup

Continue in the isolation mode selected before Phase 1. Do not create a second branch or worktree unless the user asks to change modes.

### Rules during implementation

- Follow CLAUDE.md conventions strictly (naming, server-first, no `any`, etc.).
- Work in logical checkpoints (schema, API, UI, tests). At each checkpoint, run `pnpm typecheck && pnpm lint && pnpm test`, then tell the user the checkpoint is ready and suggest invoking `incu-way-prepare-pr` to commit it — do not run `git add`/`git commit` yourself.
- All PRD functional requirements must map to at least one test.

### Suggested commit message format (for `incu-way-prepare-pr` to use)

```
feat({slug}): {short description}

- Requirement FR-N implemented
- Tests added: {what}
```

---

## Phase 4 — Validation

**Goal:** Verify implementation against PRD before handing off to the user.

### Checklist (run before asking user to test)

- [ ] Every functional requirement from the PRD has been implemented.
- [ ] Every item in the test plan is green (`pnpm test`, `pnpm test:e2e`).
- [ ] `pnpm typecheck` exits 0.
- [ ] `pnpm lint` exits 0.
- [ ] `pnpm build` succeeds.
- [ ] No regressions in existing tests.
- [ ] Open questions from the PRD are resolved (or documented as deferred).
- [ ] PRD status updated to `In Progress → Done` (or `Ready for Review`).
- [ ] Snyk code scan clean (no new issues).
- [ ] Snyk dependency scan clean (no new issues).
- [ ] SonarQube scan clean (no new issues).

### Security scan (mandatory before Gate 3)

Run all three scans against the selected working location. Fix every issue **introduced by this feature's commits** — pre-existing issues in `main`/`develop` are out of scope unless the fix is trivial. Re-scan after each fix cycle until clean.

**Snyk — source code (SAST):**
Use the `snyk_code_scan` MCP tool:
```
path: <absolute path to the selected working location>
severity_threshold: low
```

**Snyk — dependencies (SCA):**
Use the `snyk_sca_scan` MCP tool:
```
path: <absolute path to the selected working location>
severity_threshold: low
all_projects: true
```
If the folder is not yet trusted, call `snyk_trust` first with the same path.

**SonarQube:**
```bash
bash run-sonar.sh
```
Review the output for issues tagged to files modified in this feature branch. Fix any `BLOCKER` or `CRITICAL` severity issues introduced by new code.

If `snyk_trust`, `snyk_code_scan`, `snyk_sca_scan`, or `run-sonar.sh` is unavailable, record the missing tool in `docs/prds/{slug}/TESTING.md`, include the exact command or tool name that failed, and ask the user whether to install/configure it or proceed with the available validation only. Do not report the scan as clean when it did not run.

**Fix loop:**
1. Address every new issue flagged (upgrade vulnerable dependency, sanitize input, etc.).
2. Run `pnpm typecheck && pnpm lint && pnpm test` to confirm nothing broke.
3. Suggest invoking `incu-way-prepare-pr` to commit the fix (`fix({slug}): address snyk/sonar findings`) — do not commit it yourself.
4. Re-run all three scans.
5. Repeat until all three scans report zero new issues.

### Gate 3 — User testing

After validation passes:
- Write a short **testing guide** at `docs/prds/{slug}/TESTING.md`:
  - How to start the feature (URL, CLI command, etc.)
  - Step-by-step scenarios to exercise (happy path + edge cases)
  - Known limitations or deferred items
- Say: **"Implementation complete and validated. Testing guide at `docs/prds/{slug}/TESTING.md`. Please test and let me know."**
- **Stop. Wait for user feedback.**

---

## Phase 5 — Merge via Pull Requests

**Goal:** Integrate the feature into `develop` and then `main` through reviewed PRs. Never merge branches directly — always use PRs.

### Branch flow

```
feat/{slug}  →  develop  →  main
               (PR 1)      (PR 2)
```

### PR 1 — feat/{slug} → develop

After the user validates (Gate 3 passed), tell the user the branch is ready and suggest invoking `incu-way-prepare-pr` to push `feat/{slug}` and open the PR to `develop`. Do not push or run `gh pr create` yourself — `incu-way-prepare-pr` is the only skill that does that, and only when the user asks it to.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: feat({slug}): {short feature name}
```

**PR body must include:**
- **Summary:** 2-4 bullets describing what was built and why.
- **PRD:** link to `docs/prds/{slug}/PRD.md`.
- **Testing:** link to `docs/prds/{slug}/TESTING.md`.
- **Checklist:** typecheck ✅, lint ✅, tests ✅, build ✅, snyk-code ✅, snyk-deps ✅, sonarqube ✅, user validated ✅.

Once opened, share the PR URL with the user. **Stop. Do not merge until the user approves the PR.**

### PR 2 — develop → main

After PR 1 is merged to `develop`, suggest invoking `incu-way-prepare-pr` again to open the PR from `develop` → `main`.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: release: {slug} — {short feature name}
```

**PR body must include:**
- What features/fixes are included in this release.
- Link to the develop → feat PR for full diff context.

Once opened, share the PR URL with the user. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | PRD written | "PRD draft ready at `docs/prds/{slug}/PRD.md`. Please review." | User says OK |
| 2 | Plan written | "Implementation plan ready at `docs/prds/{slug}/PLAN.md`. Please review." | User says OK |
| 3 | Security scans clean + validation passes | "Implementation complete. Testing guide at `docs/prds/{slug}/TESTING.md`. Please test." | User feedback |
| 4 | User validated | Suggest `incu-way-prepare-pr` for PR feat→develop; share URL once user runs it | User approves PR |
| 5 | PR 1 merged | Suggest `incu-way-prepare-pr` for PR develop→main; share URL once user runs it | User approves PR |

---

## File layout per feature

```
docs/prds/{prd-slug}/
  PRD.md        # Feature spec (Phase 1)
  PLAN.md       # Implementation plan (Phase 2)
  TESTING.md    # Testing guide (Phase 4)
```

---

## What NOT to do

- Do not write code before Gate 1 is cleared.
- Do not start implementation before Gate 2 is cleared.
- Do not merge to `main` without user sign-off after Gate 3.
- **Never merge branches directly** — always via PR, regardless of how small the change.
- Do not invent client requirements, implied scope, or acceptance criteria during discovery, PRD drafting, or planning.
- Do not draft the PRD if the request is still ambiguous enough that client expectations, constraints, or likely affected areas are unclear.
- Do not invent requirements not in the PRD — if something is unclear, add it to Open Questions and surface it at Gate 1.
- Do not skip `pnpm typecheck && pnpm lint && pnpm test` before declaring implementation done.
