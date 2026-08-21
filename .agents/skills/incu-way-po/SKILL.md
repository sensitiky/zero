---
name: incu-way-po
version: 0.1.0
description: Use to turn a raw need, idea, or client request into development-ready tickets before any development flow starts — validate feasibility against the actual codebase(s), map affected repos and cross-repo contracts, and close open questions up front. Trigger for "refine this ticket", "write the requirements for X", "is X feasible", "prepare tickets for this need", or when a request spans multiple repositories. Do not trigger for tickets that are already well-specified, plain defect reports (use incu-way-bugs), or when the user asks to start building immediately.
---

# Product Ownership Process

A gate-driven workflow for turning a raw need into one or more **development-ready
tickets** — each validated against the actual codebase(s): what is possible, what is not,
what it touches, and what still needs a human decision. The goal is that open questions
get answered *before* `incu-way-development` or `incu-way-bugs` starts, not during it.

This flow sits **upstream** of the development flows:

```
raw need ──▶ incu-way-po ──▶ TICKET.md (Ready) ──▶ incu-way-development (Phase 0 consumes it)
                                                └▶ incu-way-bugs (for defect-shaped items)
```

This is an **analytical flow**. Like `incu-way-docs` and the assessments, it does **not**
maintain a `.ways/state.json`. It writes requirement documents, never code. Output lives
in `docs/requirements/{slug}/TICKET.md` — one folder per ticket, and the ticket slug is
designed to become the PRD slug when development starts.

Keep it **scaled to the need.** A small, single-repo change needs a short feasibility
pass and one ticket — not a discovery project. Depth follows ambiguity and blast radius.

---

## Phase 0 — Intake and feasibility survey (read-only)

**Goal:** Understand the need and the ground truth of the code well enough to say what is
possible, what is not, and what must be decided by a human. No files are written in this
phase.

### Intake

1. Capture the need in product terms:
   - what problem is being solved, and who feels it
   - what outcome the client or stakeholder expects
   - constraints and non-goals already known
   - how success would be measured
2. Read the existing product context: `PRD.md`, `docs/`, prior tickets in
   `docs/requirements/`, and related PRDs in `docs/prds/`.

### Identify the affected repositories

3. Ask the user which repositories are in scope for this product, or read the repo list
   from the hub repo's `CLAUDE.md` (a `repos:` section) if one exists. For single-repo
   products this is trivial; for multi-repo products (e.g. a web app + API + workers),
   list every repo the need may touch before surveying.

### Feasibility pass (per repo, grounded in code)

4. Survey each in-scope repo **read-only**: current behavior related to the need, likely
   affected modules, entry points, integrations, and existing patterns to preserve.
5. Record the feasibility picture, traceable to `repo:path:line` — no invention:
   - what the current system already supports
   - what is possible with reasonable effort
   - what is **not** possible without larger changes (and why)
   - which cross-repo contracts change: APIs, events, schemas, shared packages — and the
     ordering constraints between repos that follow
6. Collect every unknown as an explicit **open question** — never as an assumption. Tag
   each one: needs the user/stakeholder now, or resolvable by more survey work.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- the problem and the expected outcome, in product terms
- the repositories and modules likely affected
- the feasibility picture: supported today / possible / not possible without larger work
- the cross-repo contract changes and their ordering constraints (multi-repo needs)
- the open questions, each tagged by who can resolve it

Do not infer behavior from a name or a README claim. If the code does not make something
clear, it is an open question — not an assumption.

---

## Gate 1 — Scope and ticket split

Propose, before writing any ticket:

```markdown
## Proposed scope and split

- **Need:** {one-line restatement}
- **In scope / out of scope:** {explicit}
- **Ticket split:** {one ticket, or several — per repo, per increment, or feature vs bug —
  each independently deliverable, with slugs and dependency order}
- **Feasibility summary:** {supported today / possible / not possible without larger work}
- **Open questions needing you now:** {list}
- **Open questions I can still resolve by survey:** {list}
```

- Ask: **"This is the proposed scope and ticket split for {need}. Confirm it before I draft the tickets."**
- **Stop. Do not draft tickets until the user confirms the scope and split.**

---

## Isolation setup (after Gate 1)

Before writing any file, ask the user how they want to isolate the work:

> Do you want me to work in a new branch in the current checkout, or create a separate git worktree?

Use the user's answer exactly:
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branches or creating a worktree.

Tickets are written in the product's **hub repo** (the one that owns `docs/`), even when
the need spans several repositories — the other repos are only read during the survey.

### Option A — Branch in current checkout

```bash
# Run from the repo root
git switch develop
git pull --ff-only
git switch -c po/{slug}
```

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/po-{slug} -b po/{slug} origin/develop
```

`{slug}` here is the need's slug (e.g. `po/contact-export`). All output is written inside
the selected working location. Never write files to `develop` or `main` directly.

---

## Phase 2 — Draft the tickets

**Goal:** One `docs/requirements/{ticket-slug}/TICKET.md` per ticket from the approved
split.

**Slug format:** `{zero-padded-id}-{kebab-ticket-name}` (e.g. `004-contact-export-api`).
IDs are sequential across `docs/requirements/` **and** `docs/prds/` — check both to find
the next ID, because the ticket slug becomes the PRD slug when development picks it up.

### TICKET.md structure

```markdown
# Ticket — {title}

## Status
Draft | In Review | Ready | Handed off

## Problem / outcome
What pain, for whom, what changes when it ships.

## Scope
In / out. Explicit non-goals.

## Feasibility notes
What the codebase already supports, what this requires, what is not possible without
larger work — each point traceable to `repo:path:line`.

## Affected repositories / modules
| Repo | Modules touched | Nature of change (code / contract / config) |
|------|-----------------|----------------------------------------------|

## Cross-repo dependencies
API/event/schema contracts that change, and the ordering constraints between tickets
or repos. "None" for single-repo tickets.

## Acceptance criteria
Numbered, concrete, testable. These become the PRD's functional requirements.

## Risks / assumptions
Explicitly labeled; every assumption must be confirmed or promoted to an open question.

## Open questions
Must be empty — or every remaining item explicitly marked "deferred, accepted by {who}"
— before the ticket can be marked Ready.

## Suggested flow
incu-way-development | incu-way-bugs (with the suggested slug)
```

### Drafting rules (non-negotiable)

- **Traceable.** Every feasibility claim cites `repo:path:line`. If it cannot be cited,
  it is an open question.
- **Testable.** Every acceptance criterion is concrete enough to become a test.
- **No invention.** Do not add requirements, scope, or acceptance criteria the user did
  not state or confirm at Gate 1.
- **Cross-repo explicit.** For multi-repo needs, the contract changes and ordering
  constraints are in the ticket, not in Claude's head.

---

## Gate 2 — Definition of Ready review

For each ticket, present the **Definition of Ready checklist**:

- [ ] Problem and outcome stated in product terms
- [ ] Scope and non-goals explicit
- [ ] Feasibility validated against actual code (traceable)
- [ ] Affected repos/modules mapped; cross-repo contracts identified
- [ ] Acceptance criteria concrete and testable
- [ ] Open questions resolved, or explicitly deferred with the user's acceptance

- Say: **"Ticket(s) ready at `docs/requirements/{slug}/`. The Definition of Ready checklist is included for your review."**
- **Stop. Wait for user review.**

A ticket does not leave this gate as `Ready` while its Open questions section has
unresolved items. Iterate here — resolving a question may change the split, the
feasibility notes, or the acceptance criteria — until the user marks each ticket Ready
or explicitly accepts the deferred items.

---

## Phase 3 — Hand-off

Once the user approves at Gate 2:

- Update each ticket's status to `Ready`.
- **Jira sync (optional, user-triggered only):** if the user explicitly asks (e.g.
  "create the Jira tickets", "sync this to Jira"), create or update the Jira issue(s)
  from TICKET.md via the Atlassian MCP tools, and record the issue key in the ticket.
  Never create, update, or transition Jira issues without that explicit request — the
  same philosophy `incu-way-prepare-pr` applies to git persistence.
- Point to the next step: for each ticket, its **Suggested flow** — when
  `incu-way-development` (or `incu-way-bugs`) starts, its Phase 0 reads the TICKET.md
  and treats the acceptance criteria as the starting functional requirements.

---

## Gate 3 — PR

Suggest invoking `incu-way-prepare-pr` to push `po/{slug}` and open the PR to `develop`.
Do not push or open the PR yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: po({slug}): {short need name}
```

**PR body must include:**
- **Need:** the problem and expected outcome.
- **Tickets:** the list of `docs/requirements/{slug}/TICKET.md` files and their status.
- **Split rationale:** why this split, and the dependency order (multi-repo needs).
- **Open questions:** resolved count, and any explicitly deferred items with who accepted them.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Scope + split proposed | "This is the proposed scope and ticket split for {need}. Confirm it before I draft the tickets." | User confirms |
| 2 | Ticket(s) drafted | "Ticket(s) ready at `docs/requirements/{slug}/`. The Definition of Ready checklist is included for your review." | User review |
| 3 | Tickets Ready | Suggest `incu-way-prepare-pr` for PR `po/{slug} → develop`; share URL once user runs it | User approves PR |

---

## What gets produced

```
docs/requirements/{ticket-slug}/
  TICKET.md   # Problem, scope, feasibility notes, repo map, acceptance criteria, open questions
```

---

## What NOT to do

- Do not draft tickets before Gate 1 confirms the scope and the split.
- Do not mark a ticket `Ready` with unresolved open questions — resolve them or get the
  user's explicit acceptance to defer them.
- Do not make untraceable feasibility claims — cite `repo:path:line` or record an open
  question.
- Do not invent requirements, scope, or acceptance criteria the user did not confirm.
- Do not create, update, or transition Jira issues unless the user explicitly asks for it
  in that moment.
- Do not write code, PRDs, or plans here — this flow ends where `incu-way-development`
  and `incu-way-bugs` begin.
- Do not write into the surveyed repositories — they are read-only during the survey;
  tickets live in the hub repo.
- Do not write directly to `develop` or `main` — use `po/{slug}`.
