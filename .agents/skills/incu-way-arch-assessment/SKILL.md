---
name: incu-way-arch-assessment
version: 0.1.0
description: Use to assess the software architecture of a codebase, a module, or the current branch's changes against quality attributes and design principles (coupling/cohesion, layering/hexagonal adherence, separation of concerns, scalability, maintainability, testability). Produces a traceable assessment report with rated findings and prioritized recommendations. Invoke standalone to audit a system or design, or from another flow (incu-way-development at planning, incu-way-docs, incu-way-init) to evaluate a proposed or existing design before committing to it. Especially important before a large change, a refactor decision, or when tech debt and structural risk need to be made explicit.
---

# Architectural Assessment Process

A gate-driven workflow for evaluating an architecture — a whole system, a module, or the
changes on the current branch — against explicit quality attributes and design principles,
and turning that into a **traceable, prioritized assessment** that a team can act on. The
output lives in `docs/assessments/arch/{slug}/ASSESSMENT.md`.

Two invocation modes:

- **Standalone (audit a system or a design):** own branch `assess/arch-{slug}` → PR to `develop`.
- **Embedded in another flow:** write into the **caller's current branch/worktree**; the
  assessment ships with that flow's PR. No separate branch or PR. Examples:
  `incu-way-development` evaluating a planned design at Gate 2, `incu-way-docs` flagging
  structural risk while documenting, `incu-way-init` sizing up a brownfield repo.

This is an **assessment flow**. Like `incu-way-docs`, it does **not** maintain a
`.ways/state.json` (that model is for `feature` / `bug` / `security` work). It
assesses and recommends — it does **not** implement fixes. Acting on a recommendation is a
separate `incu-way-development` or `incu-way-bugs` work item.

---

## Phase 0 — Scope and survey

**Goal:** Understand what is being assessed and against which lens, before judging anything.
Read-only.

### Intake

1. Confirm the **target** with the available context:
   - whole repo, a specific module/service/bounded context, or **the current branch's diff**
     (a proposed change or new code — `git diff develop...HEAD`)
   - whether this is an **as-built** audit (existing code) or an **as-designed** review (a
     plan/PRD/proposal not yet implemented)
2. Read the existing architecture docs first (`docs/architecture/`, `README.md`, `PRD.md`,
   any ADRs) to ground the assessment and avoid re-deriving what is already written. If they
   are missing or stale, note it — that is itself a finding.

### Survey the target

Survey, do not yet judge:

- **Decomposition** — the real top-level structure (layers, hexagonal ports/adapters,
  feature folders, microservices) and whether the code matches the documented intent.
- **Dependencies** — module/package dependency direction; cycles; coupling hotspots;
  what depends on what.
- **Boundaries** — where domain logic lives vs. infrastructure/framework code; leakage
  across boundaries.
- **Cross-cutting concerns** — auth, config, logging/observability, error handling,
  transactions — where each lives and whether it is consistent.
- **Data & integrations** — stores, external systems, and how the code reaches them.
- **Tests** — what layers are covered, what shape the tests take, what is untestable.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- the target and whether it is as-built or as-designed
- the main components and their real dependency relationships
- which existing docs were used and which are missing/stale
- the candidate quality attributes that matter for this system
- which areas are unclear and will be marked as open questions rather than assumed

Do not infer a design property from a name. If the code does not make a structural fact
clear, it becomes an open question — not a confident claim.

---

## Gate 1 — Assessment scope and criteria

Propose **what is assessed** and **the criteria it is assessed against**, scaled to the
target (a single module needs a lighter lens than a multi-service platform). Present it:

```markdown
## Proposed assessment

- **Target:** {repo | module X | current branch diff}
- **Mode:** as-built audit | as-designed review
- **Quality attributes (rated):**
  - [ ] Maintainability / modularity
  - [ ] Coupling & cohesion
  - [ ] Layering / boundary integrity (hexagonal, SoC)
  - [ ] Scalability & performance posture
  - [ ] Testability
  - [ ] Security posture (structural — defer deep checks to incu-way-security-validation)
  - [ ] Observability & operability
  - [ ] Consistency with documented architecture
- **Out of scope:** {what this pass will not cover}
- **Open questions:** {anything ambiguous about the target or intent}
```

- Trim attributes the target doesn't warrant; add any specific to it.
- Ask: **"This is the assessment scope and criteria for {target}. Confirm it before I start the assessment."**
- **Stop. Do not produce the assessment until the user confirms the scope and criteria.**

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
git switch -c assess/arch-{slug}
```

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/assess-arch-{slug} -b assess/arch-{slug} origin/develop
```

`{slug}` is `{kebab-target}` (e.g. `payments-core`, `checkout-redesign`). All output is
written and committed inside the selected working location.

---

## Phase 2 — Author the assessment

**Goal:** Produce `ASSESSMENT.md`, grounded in the actual code/design.

### Assessment rules (non-negotiable)

- **Traceable.** Every finding points to its evidence — `path/to/file.ext:line`, a module,
  a dependency edge, or a config key. A reader must be able to verify it.
- **No invention.** Assess what exists, not what "should" exist. If a property is unclear,
  it goes under **Open questions / to verify** — never guess a rating.
- **Rate, don't just describe.** Each quality attribute gets a rating and the evidence
  behind it, not a vague adjective.
- **Severity reflects risk, not taste.** A finding's severity is the architectural risk it
  carries (blast radius, likelihood of causing defects, cost to change later) — not personal
  style preference.
- **Recommend, don't implement.** Recommendations are concrete and prioritized; this flow
  does not change code.
- **Conflicts get recorded.** If the code contradicts the documented architecture, state the
  contradiction explicitly rather than picking a side silently.

### ASSESSMENT.md structure

```markdown
# Architectural Assessment — {target}

## Scope
- Target: {repo | module | branch diff}
- Mode: as-built | as-designed
- Date: {YYYY-MM-DD}
- Criteria: {the attributes confirmed at Gate 1}

## Executive summary
3–5 sentences: overall health, the one or two things that matter most, the headline risks.

## Quality attribute ratings
| Attribute | Rating | Evidence | Notes |
|-----------|--------|----------|-------|
| Maintainability | Strong / Adequate / At risk / Poor | `path:line`, module | … |
| Coupling & cohesion | … | … | … |
| Layering / boundaries | … | … | … |
| Scalability | … | … | … |
| Testability | … | … | … |

## Strengths
What is genuinely well-structured and should be preserved (each with evidence).

## Findings
| # | Area | Severity | Finding | Evidence | Recommendation |
|---|------|----------|---------|----------|----------------|
| 1 | Coupling | High | Domain layer imports the HTTP framework directly | `src/domain/order.ts:12` | Introduce a port; move the dependency to the adapter |
| 2 | … | … | … | … | … |

Severity: Critical / High / Medium / Low — architectural risk, not style.

## Tech debt register
Debt items worth tracking, each with rough cost-to-fix and cost-of-delay.

## Open questions / to verify
- …
```

Keep prose tight: short, direct sentences; tables over paragraphs where they read better.

---

## Phase 3 — Diagrams and prioritization

- **Diagrams (when they clarify):** a **Mermaid** component/dependency diagram of the target
  highlighting the problem areas, and a target-state diagram if a restructure is recommended.
  **Validate every diagram against the Mermaid parser before closing** — a diagram that does
  not render is worse than none.
- **Prioritized recommendations:** order the findings' recommendations into a short
  **do-now / do-next / consider** list, each tied to its finding number. This is the actionable
  hand-off — a "do-now" item typically becomes a follow-up `incu-way-development` or
  `incu-way-bugs` work item.

---

## Gate 2 — Review

After the assessment, diagrams, and prioritization are written:

- Provide the path, the executive summary, the headline findings (by severity), and the
  **Open questions / to verify**.
- Say: **"Architectural assessment ready at `docs/assessments/arch/{slug}/ASSESSMENT.md`. Open questions are listed for your input. Please review."**
- **Stop. Wait for user review before proceeding.**

If running **embedded**, control returns to the calling flow at its own review gate — the
assessment is reviewed there and ships with that flow's PR. The standalone PR step below is
skipped.

---

## Phase 4 — PR (standalone mode only)

Suggest invoking `incu-way-prepare-pr` to push `assess/arch-{slug}` and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: assess(arch): {target}
```

**PR body must include:**
- **Scope:** target, mode, and the criteria assessed.
- **Summary:** the executive summary and the headline findings by severity.
- **Recommendations:** the do-now / do-next / consider list.
- **Open questions:** unresolved items needing team input.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Scope + criteria proposed | "This is the assessment scope and criteria for {target}. Confirm it before I start the assessment." | User confirms |
| 2 | Assessment written | "Architectural assessment ready at `docs/assessments/arch/{slug}/ASSESSMENT.md`. Please review." | User review |
| 3 | (standalone) Reviewed | Suggest `incu-way-prepare-pr` for PR `assess/arch-{slug} → develop`; share URL once user runs it | User approves PR |

---

## What gets produced

```
docs/assessments/arch/{slug}/
  ASSESSMENT.md   # ratings, findings, tech debt, prioritized recommendations, diagrams
```

---

## What NOT to do

- Do not produce the assessment before Gate 1 confirms the scope and criteria.
- Do not invent structure, intent, or a rating. Anything not verifiable goes under
  "Open questions / to verify".
- Do not make untraceable findings — every finding points to a file/module/edge/key.
- Do not set severity by style preference; severity is architectural risk.
- Do not implement fixes here — recommend, and let a follow-up `incu-way-development` /
  `incu-way-bugs` item carry the change.
- Do not close a diagram that fails to render in the Mermaid parser.
- Do not open a separate PR when embedded in another flow — the assessment ships with the
  caller's PR.
- Do not write directly to `develop` or `main` in standalone mode — use `assess/arch-{slug}`.
