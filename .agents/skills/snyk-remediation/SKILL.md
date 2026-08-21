---
name: snyk-remediation
version: 0.1.0
description: >-
  Use for Snyk-driven security work: run Snyk SAST/SCA scans, review findings, triage scope, or
  produce an approved remediation plan before fixing vulnerabilities. Trigger only when the user
  mentions Snyk, scanner findings, dependency/source vulnerabilities from Snyk, or remediation of
  Snyk results. Do not trigger for general security architecture reviews, threat models, manual
  OWASP validation, or non-Snyk bug fixes.
---

# Snyk Remediation Process

A gate-driven workflow for finding and fixing security vulnerabilities detected by Snyk without guessing about scope or acceptable risk. Start with intake and scan context, then scan, triage, plan, remediate, validate, and open PRs with explicit user confirmation at the key decision points. No fixes are applied without an approved plan.

---

## Phase 0 — Intake and Scan

**Goal:** Collect all current vulnerabilities from SAST and SCA scans.

### Steps

1. Confirm the intake context before scanning:
   - absolute project path to scan
   - whether the user wants review only, triage, or remediation
   - any urgency, environment, or business constraints already known
   - any prior scan context the user wants considered
2. If the project folder is not yet trusted, call `snyk_trust` with the absolute project path first.
3. Run SAST scan using the `snyk_code_scan` MCP tool:
   ```
   path: <absolute project path>
   severity_threshold: low
   ```
4. Run SCA scan using the `snyk_sca_scan` MCP tool:
   ```
   path: <absolute project path>
   severity_threshold: low
   all_projects: true
   ```
5. Collect all issues from both results.

If `snyk_trust`, `snyk_code_scan`, or `snyk_sca_scan` is unavailable or fails before returning findings, stop before Gate 1, report the exact missing tool or failure, and ask the user to install/configure Snyk or provide scan output. Do not fabricate findings or proceed to a remediation plan from stale data.

### Phase 0 guardrails

- Do not assume the user wants every finding fixed. The scan establishes evidence; the user establishes scope.
- Do not assume business priority from technical severity alone.
- If the path, scan target, or desired remediation scope is unclear, clarify it before proceeding.

### Phase 0 exit criteria

Before Phase 1, Claude should be able to state:
- which project path and scan target were used
- whether the user wants review only, triage, or remediation
- which business or environment constraints are already known
- that the findings list now reflects actual scan evidence rather than assumptions

---

## Phase 1 — Findings report

**Goal:** Present all findings to the user in a clear, actionable format.

### Report format

Build a Markdown table with one row per finding:

```markdown
# Snyk Security Findings — {YYYY-MM-DD}

## Summary
- SAST issues: {N} (Critical: X, High: X, Medium: X, Low: X)
- SCA issues: {N} (Critical: X, High: X, Medium: X, Low: X)
- Total: {N}

## Findings

| # | Type | Severity | Title | File / Package | CWE / CVE | Impact | Fix available |
|---|------|----------|-------|----------------|-----------|--------|---------------|
| 1 | SAST | High | SQL Injection | `lib/db/queries/contacts.ts:42` | CWE-89 | Attacker can exfiltrate DB data via crafted input | Yes — sanitize input |
| 2 | SCA  | Critical | Prototype Pollution | `lodash@4.17.15` | CVE-2019-10744 | Remote code execution via crafted payload | Yes — upgrade to `lodash@4.17.21` |
```

**Column definitions:**
- **Type:** `SAST` (source code) or `SCA` (dependency)
- **Severity:** Critical / High / Medium / Low
- **Title:** Snyk issue title
- **File / Package:** For SAST: `filePath:line`. For SCA: `package@version`
- **CWE / CVE:** CWE for SAST, CVE for SCA (when available)
- **Impact:** One sentence — what an attacker could do if exploited
- **Fix available:** Yes (with brief description) or No

### Gate 1 — Scope confirmation

After presenting the table:
- Ask the user: **"These are the findings. Which severity levels do you want to fix? (e.g., Critical + High, or all). I'll scope the remediation plan to your answer."**
- **Stop. Do not proceed until the user defines the scope.**

Do not treat scan output alone as approval to remediate. Gate 1 defines which findings are actually in scope.

---

## Isolation setup (immediately after Gate 1)

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
git switch -c fix/security-{slug}
```

All subsequent work — docs, code, commits — happens on this branch in the current checkout. Never write files to `develop` or `main` directly.

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/security-{slug} -b fix/security-{slug} origin/develop
```

All subsequent work — docs, code, commits — happens exclusively inside this worktree. Never write files to `develop` or `main` directly.

---

## State tracking — `.ways/state.json`

Follow the **ways/v1alpha1 state contract** — the canonical `.ways/state.json` format (`schemaVersion` 2), shipped as the **always-on `state-contract` rule** that `ways add` places into the project, so it is already in your context (no path to follow). Its source in this repo, for maintainers, is `ways/rulepacks/state-contract/`. Do not copy or invent a schema in this skill.

Flow-specific values:
- `flow`: `security`
- `way`: `incu/security` · `discipline`: `security` (optionally `wayVersion` from the way manifest)
- Branch pattern: `fix/security-{slug}`
- Initial `phase`: `findings`
- `isolationType`: `branch` or `worktree`, from the isolation choice
- Documents: `docs/security/{slug}/FINDINGS.md`, `docs/security/{slug}/PLAN.md`, `docs/security/{slug}/RESOLUTION.md`
- Gates: `plan`, `resolution`, `pr-develop`, `pr-main`

At session start, read `.ways/state.json` if it exists. If its `branch` matches the current `fix/security-{slug}` branch, report the current phase/next step/pending gates and resume from that state. If it does not exist, or it exists but its `branch` does not match (a stale file inherited from a merged item), start at Phase 0 and create/overwrite it at `.ways/state.json` right after the selected isolation setup after Gate 1. On each transition also update `lastPhase` (the phase you're leaving).

**Update points (phase → what to write):**

| When | `phase` | Documents / gates / steps |
|------|---------|---------------------------|
| FINDINGS.md written | `findings` | `FINDINGS.md` → `approved` |
| PLAN.md drafted | `plan` | `PLAN.md` → `in-review` |
| **Gate 2 passed (plan)** | `implementation` | `PLAN.md` → `approved`; gate `plan` → `passed`; **generate `steps` — one entry per in-scope finding, all `todo`** |
| Fixing each finding | `implementation` | mark its step `in-progress` → `done` (or `blocked`) — write the state file **per finding, immediately**, never batched at the end |
| RESOLUTION.md written | `validation` | `RESOLUTION.md` → `approved` |
| **Gate 3 passed (resolution)** | `validation` | gate `resolution` → `passed` |
| PR fix→develop opened | `pr-develop` | gate `pr-develop` → still `pending`; set its `url` to the PR link |
| PR merged to develop | `pr-develop` | gate `pr-develop` → `passed` |
| PR develop→main opened | `pr-main` | gate `pr-main` → still `pending`; set its `url` to the PR link |
| PR merged to main | `done` | gate `pr-main` → `passed` |

The `steps` generated at Gate 2 (one per in-scope finding) are what the board shows as remediation progress.

Do not commit `.ways/state.json` yourself — only write it. When the user wants to persist a checkpoint, suggest invoking `incu-way-prepare-pr`, which commits it together with the docs/code of that transition.

---

## Phase 2 — Document findings

**Goal:** Persist the findings report as the audit trail entry point.

### Where to save

Save inside the selected working location:

```
docs/security/{YYYY-MM-DD}-{short-slug}/FINDINGS.md
```

**Slug:** 2-4 word kebab summary of the main issue type, e.g.:
- `2026-05-15-xss-sqli-drizzle`
- `2026-03-10-prototype-pollution-deps`

### FINDINGS.md structure

```markdown
# Security Findings — {YYYY-MM-DD}

## Scan metadata
- Date: {YYYY-MM-DD}
- Tool: Snyk (SAST + SCA)
- Branch scanned: {branch name}
- Scope agreed: {e.g., Critical + High}

## Findings table
{paste the full table from Phase 1}

## Out of scope
{List findings the user chose NOT to fix, with a brief reason}
```

After saving:
- Say: **"Findings documented at `docs/security/{slug}/FINDINGS.md`. I'll now draft the remediation plan for the agreed scope."**
- Proceed directly to Phase 3 (no gate — user already confirmed scope in Gate 1).

---

## Phase 3 — Remediation plan

**Goal:** Design a specific, reviewable fix for each in-scope finding.

### Where to save

```
docs/security/{slug}/PLAN.md
```

### PLAN.md structure

```markdown
# Remediation Plan — {YYYY-MM-DD}

## Branch
`fix/security-{slug}`

## Isolation mode
current checkout branch | separate worktree

## Findings to fix

### Finding #1 — {Title} ({Severity})
- **Type:** SAST / SCA
- **Location:** {file:line or package@version}
- **Root cause:** {one sentence}
- **Fix approach:** {concrete action: upgrade X to Y / sanitize input at line Z / replace API call / etc.}
- **Risk of fix:** Low / Medium / High — {why}
- **Verification:** {how to confirm it's fixed: re-scan + specific test}

### Finding #2 — ...
```

### Gate 2 — Plan approval

After writing the plan:
- Say: **"Remediation plan ready at `docs/security/{slug}/PLAN.md`. Please review the fix approach for each finding before I start coding."**
- **Stop. Do not proceed until the user says OK.**

---

## Phase 4 — Implementation

**Goal:** Apply fixes in the isolated branch or worktree selected by the user.

### Setup

Continue in the isolation mode selected before Phase 2. Do not create a second branch or worktree unless the user asks to change modes.

### Rules

- Fix one finding at a time. After each one, suggest invoking `incu-way-prepare-pr` to commit it — do not commit yourself:
  ```
  fix(security): {finding title} — {CWE or CVE}
  
  Resolves finding #{N} from docs/security/{slug}/FINDINGS.md
  Fix: {one-line description of what changed}
  ```
- For **SCA upgrades:** update `package.json`, run `pnpm install`, verify no peer-dep breakage.
- For **SAST fixes:** apply the code change, add or update a test that exercises the vulnerable path.
- Run `pnpm typecheck && pnpm lint && pnpm test` after each fix, before suggesting the commit.

### Progress tracking

Update `PLAN.md` as you go — mark each finding with its commit SHA once fixed:
```markdown
- **Status:** Fixed in `abc1234`
```

---

## Phase 5 — Validation

**Goal:** Confirm all fixes are effective and no regressions were introduced.

### Steps

1. Re-run SAST scan:
   ```
   snyk_code_scan — path: <absolute path to the selected working location>, severity_threshold: low
   ```
2. Re-run SCA scan:
   ```
   snyk_sca_scan — path: <absolute path to the selected working location>, severity_threshold: low, all_projects: true
   ```
3. Run full test suite: `pnpm typecheck && pnpm lint && pnpm test && pnpm build`

### Resolution document

Save `docs/security/{slug}/RESOLUTION.md`:

```markdown
# Resolution Report — {YYYY-MM-DD}

## Re-scan results
- SAST re-scan: {N issues remaining} (was {N before})
- SCA re-scan: {N issues remaining} (was {N before})
- Fixed: {list of finding titles resolved}
- Remaining (out of scope): {list}

## Test suite
- `pnpm typecheck`: ✅ / ❌
- `pnpm lint`: ✅ / ❌
- `pnpm test`: ✅ / ❌
- `pnpm build`: ✅ / ❌

## Evidence
{Paste key output from re-scans — zero-issue confirmation or remaining out-of-scope items}
```

### Gate 3 — Validation sign-off

After writing the resolution document:
- Say: **"Fixes applied and validated. Resolution report at `docs/security/{slug}/RESOLUTION.md`. All in-scope findings resolved, tests green. Please review before I open the PR."**
- **Stop. Wait for user confirmation.**

---

## Phase 6 — Pull Request

**Goal:** Integrate the security fixes through a reviewed PR.

### Branch flow

```
fix/security-{slug}  →  develop  →  main
                         (PR 1)     (PR 2)
```

### PR 1 — fix/security-{slug} → develop

After Gate 3 is cleared, suggest invoking `incu-way-prepare-pr` to push `fix/security-{slug}` and open the PR to `develop`. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: fix(security): {short summary of what was fixed}
```

**PR body must include:**
- **Summary:** what vulnerabilities were fixed (type, severity, count).
- **Findings:** link to `docs/security/{slug}/FINDINGS.md`.
- **Plan:** link to `docs/security/{slug}/PLAN.md`.
- **Resolution:** link to `docs/security/{slug}/RESOLUTION.md`.
- **Checklist:** snyk-code ✅, snyk-deps ✅, typecheck ✅, lint ✅, tests ✅, build ✅.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

### PR 2 — develop → main

After PR 1 is merged, suggest invoking `incu-way-prepare-pr` again for the PR from `develop` → `main`:

```
Title: release(security): {slug}
Body: Promotes security remediations from fix/security-{slug}. See docs/security/{slug}/ for full audit trail.
```

Once opened, share the URL and wait for user approval.

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Findings table presented | "Which severity levels do you want to fix?" | User defines scope |
| 2 | PLAN.md written | "Plan ready at `docs/security/{slug}/PLAN.md`. Please review." | User says OK |
| 3 | RESOLUTION.md written | "Fixes validated. Review resolution report before PR." | User says OK |
| 4 | User confirms | Suggest `incu-way-prepare-pr` for PR fix→develop; share URL once user runs it | User approves PR |
| 5 | PR 1 merged | Suggest `incu-way-prepare-pr` for PR develop→main; share URL once user runs it | User approves PR |

---

## Document layout per scan

```
docs/security/{YYYY-MM-DD}-{slug}/
  FINDINGS.md    — raw scan results + agreed scope  (Phase 2)
  PLAN.md        — fix approach per finding          (Phase 3)
  RESOLUTION.md  — re-scan evidence + test results   (Phase 5)
```

---

## What NOT to do

- Do not apply any fix before Gate 2 (plan approval) is cleared.
- Do not fix out-of-scope findings without asking the user first.
- Do not assume remediation scope, acceptable risk, or business priority without explicit user direction.
- Do not translate a scan result directly into a fix plan if the intended scope or remediation tradeoff is still unclear.
- Do not skip the re-scan in Phase 5 — passing tests alone do not confirm a vulnerability is closed.
- Do not open a PR without `RESOLUTION.md` showing clean re-scan results.
- Do not merge directly — always via PR, even for trivial dependency bumps.
- Do not suppress Snyk findings with `.snyk` ignore rules without explicit user instruction.
- Do not write FINDINGS.md, PLAN.md, or any other file to `develop`/`main` before choosing the isolation mode — the branch or worktree is set up immediately after Gate 1, and all files go inside the selected working location from the start.
