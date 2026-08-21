---
name: incu-way-security-validation
version: 0.1.0
description: Use to validate code against common security rulesets and standards (OWASP Top 10, OWASP ASVS, OWASP API Security Top 10, CWE Top 25) by reviewing the code, a module, or the current branch's changes control-by-control. Produces a traceable compliance report marking each control pass/fail/N-A with evidence, plus prioritized remediation pointers. Invoke standalone to audit against a standard, or from another flow (incu-way-development at validation, incu-way-bugs) to check new code before merge. This is a standards-driven manual review — it complements snyk-remediation (automated SAST/SCA scanning), it does not replace it.
---

# Security Validation Process

A gate-driven workflow for checking code — a whole module, a service, or the changes on
the current branch — against **established security rulesets** (OWASP Top 10, OWASP ASVS,
OWASP API Security Top 10, CWE Top 25), control by control, and turning that into a
**traceable compliance report**. The output lives in
`docs/security/validation/{slug}/VALIDATION.md`.

This is a **standards/ruleset review**, distinct from `snyk-remediation`:

- `snyk-remediation` runs **automated** SAST/SCA scanners and fixes what they flag.
- This flow is a **manual, control-by-control** validation against a chosen standard —
  it catches design and logic issues scanners miss (broken access control, insecure
  business flows, missing authz checks, weak crypto choices) and maps the code to each
  control with a pass/fail verdict and evidence.

Run both for full coverage. This flow **assesses** — it does not fix by default; concrete
fixes are a follow-up `incu-way-development` / `incu-way-bugs` / `snyk-remediation` item.

Two invocation modes:

- **Standalone (audit against a standard):** own branch `assess/secval-{slug}` → PR to `develop`.
- **Embedded in another flow:** write into the **caller's current branch/worktree**; the
  report ships with that flow's PR. No separate branch or PR. Example: `incu-way-development`
  validating new code at Gate 3, alongside the Snyk/Sonar scans.

This is an **assessment flow**. Like `incu-way-docs`, it does **not** maintain a
`.ways/state.json`.

---

## Phase 0 — Scope and ruleset selection

**Goal:** Decide what is validated and against which standard(s), before judging anything.
Read-only.

### Intake

1. Confirm the **target**: whole repo, a module/service, or **the current branch's diff**
   (new code — `git diff develop...HEAD`).
2. Choose the **ruleset(s)**, scaled to the target and tech:
   - **OWASP Top 10 (2021)** — general web app baseline (default for most code).
   - **OWASP API Security Top 10 (2023)** — when the target exposes APIs.
   - **OWASP ASVS** — when a formal verification level (L1/L2/L3) is required.
   - **CWE Top 25** — language-agnostic weakness baseline.
3. Read existing security context first (`docs/security/`, prior `VALIDATION.md`,
   threat models, `CLAUDE.md` security section) to avoid re-litigating settled items and to
   align with any threat model already done (see `incu-way-threat-model`).

### Survey the target

Survey, do not yet judge: entry points and routes, authentication & session handling,
authorization checks, input handling & validation, output encoding, data access (queries,
ORM usage), secrets & config, crypto usage, file/network/external calls, error handling &
logging (and whether they leak sensitive data), dependencies in play.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- the target and whether it is the repo, a module, or the branch diff
- which ruleset(s) and (for ASVS) which level apply, and why
- the relevant entry points, trust boundaries, and sensitive operations in the target
- which existing security docs/threat models were used
- which areas are unclear and will be marked as open questions rather than assumed

Do not infer a control passes from a name or a comment. If the code does not demonstrate
the control, it is **fail** or an open question — never an assumed pass.

---

## Gate 1 — Ruleset and scope confirmation

Propose the target and the ruleset(s):

```markdown
## Proposed security validation

- **Target:** {repo | module X | current branch diff}
- **Ruleset(s):** {OWASP Top 10 2021 | OWASP API Top 10 2023 | OWASP ASVS L{1/2/3} | CWE Top 25}
- **Relevant surface:** {entry points / APIs / auth / data access in scope}
- **Out of scope:** {what this pass will not cover}
- **Relationship to scans:** {complements Snyk SAST/SCA — not a replacement}
- **Open questions:** {anything ambiguous}
```

- Ask: **"This is the security validation scope and rulesets for {target}. Confirm it before I start the validation."**
- **Stop. Do not produce the validation until the user confirms the scope and rulesets.**

---

## Isolation setup (standalone mode only)

If running **embedded in another flow**, skip this — write into the existing branch/worktree.

If running **standalone**, ask the user how they want to isolate the work before writing:

> Do you want me to work in a new branch in the current checkout, or create a separate git worktree?

Use the user's answer exactly.
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branches or creating a worktree.

### Option A — Branch in current checkout

```bash
# Run from the repo root
git switch develop
git pull --ff-only
git switch -c assess/secval-{slug}
```

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/assess-secval-{slug} -b assess/secval-{slug} origin/develop
```

`{slug}` is `{YYYY-MM-DD}-{kebab-target}` (e.g. `2026-06-17-checkout-api`). All output is
written and committed inside the selected working location.

---

## Phase 2 — Validate control by control

**Goal:** Produce `VALIDATION.md` by walking each control of the chosen ruleset(s) against
the actual code.

### Validation rules (non-negotiable)

- **Every control gets a verdict:** `Pass` / `Fail` / `N/A` / `Needs review`. No control is
  silently skipped.
- **Traceable.** A `Pass` cites the code that implements the control (`path:line`); a `Fail`
  cites the vulnerable code; `N/A` states why the control does not apply. A reader must be
  able to verify each verdict.
- **No assumed passes.** Absence of evidence is not a pass. If the control cannot be
  confirmed, it is `Needs review`, not `Pass`.
- **Impact, not just label.** Each `Fail` states what an attacker could do, plus the CWE.
- **Recommend, don't fix.** Each `Fail` gets a concrete remediation pointer; this flow does
  not change code.

### VALIDATION.md structure

```markdown
# Security Validation — {target}

## Scope
- Target: {repo | module | branch diff}
- Ruleset(s): {…}  (ASVS level: {L1/L2/L3} if applicable)
- Date: {YYYY-MM-DD}
- Branch validated: {branch}

## Summary
- Controls evaluated: {N}  (Pass: X, Fail: Y, N/A: Z, Needs review: W)
- Findings by severity: Critical X, High Y, Medium Z, Low W

## Control checklist — {ruleset name}
| Control | Verdict | Evidence | Notes |
|---------|---------|----------|-------|
| A01 Broken Access Control | Fail | `src/api/orders.ts:30` — no ownership check on GET /orders/:id | IDOR: any user reads any order |
| A02 Cryptographic Failures | Pass | `src/auth/hash.ts:8` — bcrypt cost 12 | |
| A03 Injection | Pass | parameterized queries throughout `src/db/` | |
| … | … | … | … |

## Findings (the fails, detailed)
| # | Control | Severity | CWE | Finding | Evidence | Impact | Remediation |
|---|---------|----------|-----|---------|----------|--------|-------------|
| 1 | A01 | High | CWE-639 | IDOR on order read | `src/api/orders.ts:30` | Any user reads any order | Enforce ownership/authz check before returning the record |
| 2 | … | … | … | … | … | … | … |

## Needs review
Controls that could not be confirmed and need a human/code answer.

## Out of scope
Controls or areas deliberately not covered, with reason.
```

For a multi-ruleset pass, repeat the control checklist table per ruleset; keep one combined
findings table.

---

## Phase 3 — Findings and remediation hand-off

- **Prioritize** the findings (Critical/High first) into a short remediation list, each tied
  to its finding number.
- **Route the fixes** explicitly — this flow does not implement them:
  - dependency vulnerabilities / scanner-detectable issues → `snyk-remediation`
  - logic/access-control/design fixes in existing behavior → `incu-way-bugs`
  - fixes that are part of a feature being built → fold into that `incu-way-development` item
- Note the routing against each finding so the hand-off is unambiguous.

---

## Gate 2 — Review

After the validation is written:

- Provide the path, the summary counts, the fails by severity, and the **Needs review** list.
- Say: **"Security validation ready at `docs/security/validation/{slug}/VALIDATION.md`. Findings are routed for remediation and open items are listed. Please review."**
- **Stop. Wait for user review before proceeding.**

If running **embedded**, control returns to the calling flow at its own validation/review
gate — the report is reviewed there and ships with that flow's PR. The standalone PR step
below is skipped.

---

## Phase 4 — PR (standalone mode only)

Suggest invoking `incu-way-prepare-pr` to push `assess/secval-{slug}` and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: assess(security): validate {target} against {ruleset}
```

**PR body must include:**
- **Scope:** target, ruleset(s), and ASVS level if any.
- **Summary:** pass/fail counts and findings by severity.
- **Findings & routing:** the prioritized fails and where each fix is routed.
- **Needs review:** unconfirmed controls needing team input.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Ruleset + scope proposed | "This is the security validation scope and rulesets for {target}. Confirm it before I start." | User confirms |
| 2 | Validation written | "Security validation ready at `docs/security/validation/{slug}/VALIDATION.md`. Please review." | User review |
| 3 | (standalone) Reviewed | Suggest `incu-way-prepare-pr` for PR `assess/secval-{slug} → develop`; share URL once user runs it | User approves PR |

---

## What gets produced

```
docs/security/validation/{slug}/
  VALIDATION.md   # per-ruleset control checklist + detailed findings + remediation routing
```

---

## What NOT to do

- Do not produce the validation before Gate 1 confirms the scope and rulesets.
- Do not mark a control `Pass` without evidence — unconfirmed is `Needs review`, never `Pass`.
- Do not make untraceable verdicts — each cites code, or states why N/A.
- Do not treat this as a replacement for the Snyk SAST/SCA scans — it complements them.
- Do not implement fixes here — validate, route the remediation, and let the target flow
  carry the change.
- Do not open a separate PR when embedded in another flow — the report ships with the
  caller's PR.
- Do not write directly to `develop` or `main` in standalone mode — use `assess/secval-{slug}`.
