---
name: incu-way-threat-model
version: 0.1.0
description: Use to build a small, focused threat model for the current work or new code — a feature, a service, an API, or the changes on the current branch. Decomposes the system into assets, entry points, and trust boundaries, enumerates threats with STRIDE, and records mitigations and residual risk in a traceable report with a data-flow diagram. Invoke standalone to threat-model a component, or from another flow (incu-way-development after the PRD/plan, incu-way-bugs for a security-relevant fix) to surface threats before code is written or shipped. Especially important for new external surfaces, auth/payment/PII flows, or trust-boundary changes.
---

# Threat Modeling Process

A gate-driven workflow for producing a **small, focused threat model** of the current work
— a planned feature, a module, an API, or the changes on the current branch — using a
lightweight STRIDE pass over the system's data flows and trust boundaries. The goal is a
practical, traceable model that drives mitigations, not an exhaustive enterprise artifact.
The output lives in `docs/security/threat-models/{slug}/THREAT-MODEL.md`.

Two invocation modes:

- **Standalone (threat-model a component or change):** own branch `assess/threat-{slug}` → PR
  to `develop`.
- **Embedded in another flow:** write into the **caller's current branch/worktree**; the model
  ships with that flow's PR. No separate branch or PR. Examples: `incu-way-development`
  running a threat model right after the PLAN at Gate 2 (so mitigations become plan tasks);
  `incu-way-bugs` modeling a security-relevant fix.

This is an **assessment flow**. Like `incu-way-docs`, it does **not** maintain a
`.ways/state.json`. It identifies threats and proposes mitigations — implementing
a mitigation is a task in the calling flow or a follow-up `incu-way-development` /
`incu-way-bugs` item.

Keep it **small.** Scale the model to the change: a single new endpoint needs one data-flow
diagram and a handful of threats, not a 40-page document. Depth follows risk.

---

## Phase 0 — Scope and decomposition

**Goal:** Understand the system slice well enough to reason about threats. Read-only.

### Intake

1. Confirm the **target**: a planned feature (from its PRD/PLAN), a module/service, an API,
   or **the current branch's diff** (new code).
2. Read the relevant context first: the PRD/PLAN (if embedded in development), existing
   `docs/architecture/`, any prior threat model, the `CLAUDE.md` security section, and a
   `VALIDATION.md` if one exists (see `incu-way-security-validation`).

### Decompose the target

Identify, grounded in the code/design:

- **Assets** — what is worth protecting (PII, credentials, payment data, tokens, money
  movement, integrity of records, availability of a flow).
- **Actors** — who interacts (end users, admins, anonymous callers, internal services,
  third parties), and their privilege levels.
- **Entry points** — routes, endpoints, message consumers, file/uploads, CLI, scheduled jobs.
- **Trust boundaries** — where data crosses a privilege/ownership change (internet→service,
  service→DB, service→third-party, tenant→tenant).
- **Data flows** — how data moves between actors, processes, and stores across those
  boundaries.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- the target and what slice of the system it covers
- the key assets and actors
- the entry points and trust boundaries in scope
- the main data flows that cross those boundaries
- which areas are unclear and will be marked as open questions rather than assumed

Do not infer a control or boundary from a name. If the design does not make a flow clear,
it is an open question — not an assumption.

---

## Gate 1 — Scope and decomposition

Propose the model's scope and the decomposition, scaled to the change:

```markdown
## Proposed threat model

- **Target:** {feature X | module | API | current branch diff}
- **Assets:** {what we're protecting}
- **Actors:** {who, with privilege level}
- **Entry points:** {routes / consumers / jobs in scope}
- **Trust boundaries:** {the crossings to model}
- **Method:** STRIDE per data-flow element
- **Out of scope:** {what this model will not cover}
- **Open questions:** {anything ambiguous}
```

- Ask: **"This is the threat model scope and decomposition for {target}. Confirm it before I enumerate threats."**
- **Stop. Do not enumerate threats until the user confirms the scope and decomposition.**

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
git switch -c assess/threat-{slug}
```

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/assess-threat-{slug} -b assess/threat-{slug} origin/develop
```

`{slug}` is `{kebab-target}` (e.g. `pay-by-link`, `contact-export-api`). All output is
written and committed inside the selected working location.

---

## Phase 2 — Enumerate threats (STRIDE)

**Goal:** Produce `THREAT-MODEL.md` — a data-flow diagram plus a STRIDE pass over each
element/boundary, grounded in the actual design.

### Threat modeling rules (non-negotiable)

- **STRIDE per element.** For each data flow / process / store / boundary, consider
  Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of
  privilege. Record the ones that genuinely apply — do not pad with non-applicable rows.
- **Traceable.** Each threat references the element/flow it targets and, where it exists, the
  code/design point (`path:line`, route, boundary). Each mitigation that already exists cites
  where it lives; each proposed one is concrete.
- **Rate the risk.** Each threat gets Likelihood × Impact (or a Low/Med/High risk). That is
  what orders the mitigations.
- **No invention.** If whether a mitigation exists is unclear, mark the threat's status
  `Unverified` and add an open question — never assume the defense is in place.
- **Residual risk is explicit.** State what remains after the proposed mitigations and what
  is accepted.

### THREAT-MODEL.md structure

```markdown
# Threat Model — {target}

## Scope
- Target: {feature | module | API | branch diff}
- Date: {YYYY-MM-DD}
- Method: STRIDE
- Assets / actors / trust boundaries: {short recap from Gate 1}

## Data-flow diagram
{Mermaid DFD: actors, processes, data stores, and trust boundaries as labeled crossings}

## Threats (STRIDE)
| # | Element / flow | STRIDE | Threat | Likelihood | Impact | Risk | Existing mitigation | Proposed mitigation | Status |
|---|----------------|--------|--------|------------|--------|------|---------------------|---------------------|--------|
| 1 | POST /login | S | Credential stuffing via unthrottled login | High | High | High | none | Rate-limit + lockout + MFA option | Open |
| 2 | service→DB | T | SQLi via unparameterized query | Med | High | High | parameterized queries `src/db/q.ts:20` | — | Mitigated |
| 3 | order read | E | IDOR — no ownership check | Med | High | High | none | Enforce authz on record access | Open |

Status: Mitigated / Open / Accepted / Unverified.

## Prioritized mitigations
Ordered by risk; each tied to its threat number. (These become plan tasks or follow-up items.)

## Residual risk
What remains after the proposed mitigations, and what is explicitly accepted (and by whom).

## Open questions / to verify
- …
```

**Validate the Mermaid DFD against the parser before closing** — a diagram that does not
render is worse than none. Keep it readable; split if overcrowded.

---

## Phase 3 — Mitigations and residual risk

- **Prioritize** the open threats by risk into the mitigation list, each tied to its threat
  number.
- **Hand off** the mitigations explicitly — this flow does not implement them:
  - if embedded in `incu-way-development`, each "Open" high/medium mitigation should become a
    **task in the PLAN** before coding starts
  - otherwise route to a follow-up `incu-way-development` / `incu-way-bugs` / `snyk-remediation`
    item as appropriate
- **State residual risk** plainly so the user can accept it knowingly.

---

## Gate 2 — Review

After the model is written:

- Provide the path, the high-risk threats, the prioritized mitigations, the residual risk,
  and the **Open questions / to verify**.
- Say: **"Threat model ready at `docs/security/threat-models/{slug}/THREAT-MODEL.md`. High-risk threats and proposed mitigations are listed for your review. Please review."**
- **Stop. Wait for user review before proceeding.**

If running **embedded**, control returns to the calling flow at its own gate — the model is
reviewed there, its mitigations fold into that flow's plan, and it ships with that flow's PR.
The standalone PR step below is skipped.

---

## Phase 4 — PR (standalone mode only)

Suggest invoking `incu-way-prepare-pr` to push `assess/threat-{slug}` and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: assess(threat-model): {target}
```

**PR body must include:**
- **Scope:** target, assets, actors, trust boundaries.
- **Summary:** high-risk threats and their status.
- **Mitigations:** the prioritized list and where each is routed.
- **Residual risk:** what remains and what is accepted.
- **Open questions:** unresolved items needing team input.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Scope + decomposition proposed | "This is the threat model scope and decomposition for {target}. Confirm it before I enumerate threats." | User confirms |
| 2 | Model written | "Threat model ready at `docs/security/threat-models/{slug}/THREAT-MODEL.md`. Please review." | User review |
| 3 | (standalone) Reviewed | Suggest `incu-way-prepare-pr` for PR `assess/threat-{slug} → develop`; share URL once user runs it | User approves PR |

---

## What gets produced

```
docs/security/threat-models/{slug}/
  THREAT-MODEL.md   # DFD + STRIDE threat table + prioritized mitigations + residual risk
```

---

## What NOT to do

- Do not enumerate threats before Gate 1 confirms the scope and decomposition.
- Do not pad the STRIDE table with non-applicable rows — record threats that genuinely apply.
- Do not assume a mitigation is in place — if unclear, mark `Unverified` and add an open question.
- Do not make untraceable threats or mitigations — each references its element/flow and, where
  it exists, the code/design point.
- Do not implement mitigations here — model, prioritize, and let the calling flow or a
  follow-up item carry the change.
- Do not close a Mermaid DFD that fails to render in the parser.
- Do not let the model balloon — scale it to the change; depth follows risk.
- Do not open a separate PR when embedded in another flow — the model ships with the caller's PR.
- Do not write directly to `develop` or `main` in standalone mode — use `assess/threat-{slug}`.
