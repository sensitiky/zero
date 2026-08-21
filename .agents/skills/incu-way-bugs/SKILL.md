---
name: incu-way-bugs
version: 0.1.0
description: Use for bug, regression, broken behavior, or production issue reports that need expected behavior, reproduction evidence, root cause analysis, or a fix plan before code changes. Trigger when the report is incomplete, high-impact, user-facing, or likely tied to recent changes. Do not trigger for new feature work, security scan remediation, documentation-only requests, or tiny direct fixes where the user explicitly asks to patch now.
---

# Bug Fix Process

A structured, gate-driven workflow for fixing bugs without guessing. Start with discovery and intake, then move through bug documentation, analysis, reproduction, fix planning, implementation, validation, and PR review. The critical gate remains fix plan confirmation: no fix code is written before the user approves the plan.

---

## Phase 0 — Discovery and Intake

Before touching anything:

1. Read `PRD.md` and relevant docs in `docs/` to understand the affected feature.
2. Check `docs/bugs/` for any related existing reports. If a refined ticket exists for
   this issue at `docs/requirements/{slug}/TICKET.md` (produced by `incu-way-po`), read
   it first and verify — rather than re-derive — its feasibility notes and scope.
3. Clarify the issue intake:
   - what is reported to be broken
   - what should happen instead
   - who is affected
   - environment, severity, and business impact
   - which details are still missing or unverified
4. Discover the codebase context:
   - which feature area or workflow is affected
   - relevant modules, functions, tests, or integrations
   - recent commits or releases that may have introduced the regression
   - any prior bug reports, PRDs, or decisions that define expected behavior
5. Scale discovery to the case:
   - for a small, well-understood bug, keep the pass lightweight
   - for ambiguous, high-severity, or production-facing issues, dig deeper before analysis and fix planning
6. If the bug report is missing critical details, ask focused clarifying questions before moving on.

### Phase 0 exit criteria

Before Phase 1, Claude should be able to state:
- what is broken and what the expected behavior is, as currently understood
- who or what is affected
- which docs, modules, commits, or workflows are likely involved
- what assumptions are currently being made
- what still needs to be confirmed during analysis or with the user

Do not assume expected behavior, root cause, or fix direction just because a bug report sounds plausible. If important details are unclear, surface the uncertainty explicitly.

---

## Isolation setup (immediately after Phase 0)

Before creating any file, ask the user how they want to isolate the work:

> Do you want me to work in a new branch in the current checkout, or create a separate git worktree?

Use the user's answer exactly:
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branches or creating a worktree.

### Option A — Branch in current checkout

```bash
git switch develop
git pull --ff-only
git switch -c fix/{slug}
```

All work — BUG.md, ANALYSIS.md, tests, fix code — happens on this branch in the current checkout. Never write files to `develop` or `main` directly.

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/fix-{slug} -b fix/{slug} origin/develop
```

All work — BUG.md, ANALYSIS.md, tests, fix code — happens exclusively inside this worktree.

---

## State tracking — `.ways/state.json`

Follow the **ways/v1alpha1 state contract** — the canonical `.ways/state.json` format (`schemaVersion` 2), shipped as the **always-on `state-contract` rule** that `ways add` places into the project, so it is already in your context (no path to follow). Its source in this repo, for maintainers, is `ways/rulepacks/state-contract/`. Do not copy or invent a schema in this skill.

Flow-specific values:
- `flow`: `bug`
- `way`: `incu/bugs` · `discipline`: `development` (optionally `wayVersion` from the way manifest)
- Branch pattern: `fix/{slug}`
- Initial `phase`: `discovery`
- `isolationType`: `branch` or `worktree`, from the isolation choice in Phase 0
- Documents: `docs/bugs/{slug}/BUG.md`, `docs/bugs/{slug}/ANALYSIS.md`, `docs/bugs/{slug}/FIX_PLAN.md`
- Gates: `fix-plan`, `pr`

At session start, read `.ways/state.json` if it exists. If its `branch` matches the current `fix/{slug}` branch, report the current phase/next step/pending gates and resume from that state. If it does not exist, or it exists but its `branch` does not match (a stale file inherited from a merged item), start at Phase 0 and create/overwrite it at `.ways/state.json` right after the selected isolation setup. On each transition also update `lastPhase` (the phase you're leaving).

**Update points (phase → what to write):**

| When | `phase` | Documents / gates / steps |
|------|---------|---------------------------|
| BUG.md written | `document` | `BUG.md` → `approved` |
| ANALYSIS.md written | `analysis` | `ANALYSIS.md` → `approved` |
| Reproduction test added (failing) | `reproduction` | — |
| FIX_PLAN.md drafted | `fix-plan` | `FIX_PLAN.md` → `in-review` |
| **Gate passed (fix plan)** | `implementation` | `FIX_PLAN.md` → `approved`; gate `fix-plan` → `passed`; **generate `steps` from the fix plan — one entry per actionable change, all `todo`** |
| During implementation | `implementation` | mark each step `in-progress` → `done` (or `blocked`) — write the state file **per step, immediately**, never batched at the end of the phase |
| Validation | `validation` | — |
| PR fix→develop opened | `pr` | gate `pr` → still `pending`; set its `url` to the PR link |
| PR merged | `done` | gate `pr` → `passed` |

Do not commit `.ways/state.json` yourself — only write it. When the user wants to persist a checkpoint, suggest invoking `incu-way-prepare-pr`, which commits it together with the docs/code of that transition.

---

## Phase 1 — Document the Bug

**Where to save:**

```
docs/bugs/{bug-slug}/BUG.md
```

**Slug format:** `{zero-padded-id}-{kebab-description}`
Examples: `001-import-totals-zero`, `002-contact-dedup-missing`

IDs are sequential. Check existing slugs in `docs/bugs/` for the next ID.

### BUG.md structure

```markdown
# Bug — {Short Description}

## Status
Reported | Analyzing | Fix Planned | Fixing | Fixed

## Description
What is happening vs. what should happen.

## Steps to reproduce
1.
2.

## Expected behavior

## Actual behavior

## Context
- Environment: local / staging / production
- Affected commit / version:
- Affected users or records:
- Severity: Low / Medium / High / Critical

## Logs / stack trace
```

---

## Phase 2 — Analysis

**Where to save:**

```
docs/bugs/{bug-slug}/ANALYSIS.md
```

### ANALYSIS.md structure

```markdown
# Analysis — {Bug Description}

## Root cause
What is the actual underlying cause.

## Affected code
Files, functions, or modules involved.

## Impact
How many users/records affected. Any data integrity risk.

## Reproduction path
How to reliably trigger the bug.
```

Do not treat a suspected root cause as confirmed until the analysis and reproduction evidence support it.

---

## Phase 3 — Reproduction Test

Before writing any fix code, write a test that **fails** because of the bug:

1. Write a unit or e2e test that exercises the broken behavior.
2. Run it — it must fail on the current codebase.
3. Suggest invoking `incu-way-prepare-pr` to commit it (`test(fix-{slug}): add reproduction test for {bug description}`) — do not commit it yourself.

```bash
pnpm test  # Must FAIL — confirms the bug is reproduced
```

The reproduction test turning green is the definition of "fixed."

If the bug cannot be reproduced in a test, document why in ANALYSIS.md and surface it to the user before proceeding.

Do not use the reproduction phase to smuggle in a fix. The purpose here is to prove the current behavior is broken.

---

## Phase 4 — Fix Plan

**Where to save:**

```
docs/bugs/{bug-slug}/FIX_PLAN.md
```

### FIX_PLAN.md structure

```markdown
# Fix Plan — {Bug Description}

## Branch / worktree
Branch: fix/{slug}
Isolation mode: current checkout branch | separate worktree

## Root cause (one line)

## Fix approach
What will be changed and why.

## Files affected

## Risks / side effects
Could this fix break anything else?

## Rollback
How to revert if the fix introduces a regression.
```

### Gate — Fix Plan Confirmation

After writing the fix plan:
- Say: **"Fix plan ready at `docs/bugs/{slug}/FIX_PLAN.md`. Please review before I start coding."**
- **Stop. Do not write any fix code until the user says OK.**

---

## Phase 5 — Implementation

After the user approves the fix plan:

### Rules

- Fix only what's described in the fix plan — no extra cleanup.
- Run `pnpm typecheck && pnpm lint && pnpm test` at each checkpoint, then suggest invoking `incu-way-prepare-pr` to commit — do not commit yourself.
- The reproduction test from Phase 3 must be green after the fix.
- No regressions in existing tests.

### Suggested commit format (for `incu-way-prepare-pr` to use)

```
fix({slug}): {short description}

- Root cause: {one line}
- Tests: {what covers the fix}
```

---

## Phase 6 — Validation

Checklist before opening the PR:

- [ ] Reproduction test from Phase 3 is green
- [ ] All existing tests pass (`pnpm test`, `pnpm test:e2e`)
- [ ] `pnpm typecheck` exits 0
- [ ] `pnpm lint` exits 0
- [ ] `pnpm build` succeeds
- [ ] No regressions in existing tests
- [ ] BUG.md status updated to `Fixed`
- [ ] Snyk code scan clean (no new issues)
- [ ] Snyk dependency scan clean (no new issues)
- [ ] SonarQube scan clean (no new issues)

### Security scans

Same process as the development skill. Run all three scans against the selected working location. Fix every issue introduced by this fix's commits.

**Snyk SAST:**
```
snyk_code_scan: path=<absolute path to the selected working location>, severity_threshold=low
```

**Snyk SCA:**
```
snyk_sca_scan: path=<absolute path to the selected working location>, severity_threshold=low, all_projects=true
```

**SonarQube:**
```bash
bash run-sonar.sh
```

If `snyk_code_scan`, `snyk_sca_scan`, or `run-sonar.sh` is unavailable, record the missing tool in `docs/bugs/{slug}/ANALYSIS.md`, include the exact command or tool name that failed, and ask the user whether to install/configure it or proceed with the available validation only. Do not report the scan as clean when it did not run.

Fix loop: address issue → `pnpm typecheck && pnpm lint && pnpm test` → suggest `incu-way-prepare-pr` to commit → rescan → repeat until clean.

---

## Phase 7 — PR

After validation passes, suggest invoking `incu-way-prepare-pr` to push `fix/{slug}` and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: fix({slug}): {short description}
```

**PR body must include:**
- **Bug:** link to `docs/bugs/{slug}/BUG.md`
- **Root cause:** one line
- **Fix:** brief description of what changed and why
- **Tests:** reproduction test name + any other coverage added
- **Checklist:** typecheck ✅ lint ✅ tests ✅ build ✅ snyk-code ✅ snyk-deps ✅ sonarqube ✅

Once opened, share the PR URL with the user. **Stop. Do not merge until user approves.**

---

## File layout per bug

```
docs/bugs/{bug-slug}/
  BUG.md          # Bug report (Phase 1)
  ANALYSIS.md     # Root cause analysis (Phase 2)
  FIX_PLAN.md     # Fix approach + gate (Phase 4)
```

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Fix plan written | "Fix plan ready at `docs/bugs/{slug}/FIX_PLAN.md`. Please review." | User says OK |
| 2 | Validation passes | Suggest `incu-way-prepare-pr` for PR fix→develop; share URL once user runs it | User approves PR |

---

## What NOT to do

- Do not write fix code before the user approves the fix plan.
- Do not fix more than what's in the plan — extra improvements belong in a feature branch.
- Do not skip the reproduction test — if you can't reproduce the bug, say so in ANALYSIS.md and ask.
- Do not assume the expected behavior, root cause, or correct fix without evidence from docs, analysis, tests, or user clarification.
- Do not turn an incomplete bug report into a confident fix plan — surface missing details first.
- Do not skip `pnpm typecheck && pnpm lint && pnpm test` before declaring done.
- Never merge directly — always via PR.
- Never touch `develop` or `main` directly — use the isolation mode the user selected.
