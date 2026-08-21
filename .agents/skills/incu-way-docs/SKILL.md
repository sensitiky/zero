---
name: incu-way-docs
version: 0.1.0
description: Use to produce or refresh the architectural and functional documentation of an existing codebase (brownfield) so that humans and the incu-way flows understand the application. Invoked by incu-way-init during brownfield onboarding, or standalone to document a module or refresh stale docs. Especially important when the repo has real code but no living architecture docs, or when the existing docs have drifted from the code.
---

# Codebase Documentation Process

A gate-driven workflow for turning an **existing codebase** into clear, traceable
documentation: what the application is, how it is built, how its pieces fit together,
and — when it is a product with user-facing behavior — what it does functionally. The
output lives in `docs/architecture/` (and, when warranted, functional/domain docs) and
is the context the other incu-way flows read in their Phase 0.

Two invocation modes:

- **As part of `incu-way-init` (brownfield onboarding):** write into the **current init
  branch/worktree**; the docs ship with the init PR. No separate branch or PR.
- **Standalone (refresh or document a module):** own branch `docs/{slug}` → PR to `develop`.

This is a **documentation flow**. Like `incu-way-init`, it does **not** maintain a
`.ways/state.json` (that model is for `feature` / `bug` / `security` work).

---

## Phase 0 — Survey and intake

**Goal:** Understand what exists before deciding what to document. Read-only.

### Intake

1. Confirm scope with the available context:
   - whole repo, or a specific module/service/bounded context
   - depth: **architecture only**, or **architecture + functional/domain**
   - whether this is a fresh pass or a **refresh** of existing docs
2. Read what is already documented (`README.md`, `docs/`, `PRD.md`, any wiki export) to
   **avoid duplicating** and to find what has drifted.

### Inventory the codebase

Survey, do not yet write:

- **Languages / frameworks / runtime** — from manifests and config.
- **Entry points** — `main`, server bootstrap, CLI, handlers, scheduled jobs.
- **Modules / layers** — the real top-level decomposition (hexagonal, MVC, feature
  folders, microservices, …).
- **Data stores** — DBs, caches, queues, blob storage; schema/migrations location.
- **External integrations** — third-party APIs, payment/auth providers, internal
  services it calls or is called by.
- **Build / run / test / deploy** — scripts, CI config, containerization, infra-as-code.
- **Cross-cutting concerns** — auth, config, logging/observability, error handling.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- the scope and depth being documented
- the main modules/services and how they appear to relate
- the data stores and external integrations in play
- which existing docs are reused, which are stale, and which gaps remain
- which areas are unclear and will be marked as open questions rather than assumed

Do not assume how a component behaves from its name. If the code doesn't make a behavior
clear, it becomes an open question — not a confident claim.

---

## Gate 1 — Documentation map

Propose the **set of documents** to produce, scaled to the application (a small CLI
needs far less than a multi-service platform). Present it as a checklist:

```markdown
## Proposed documentation map

### Architecture (docs/architecture/)
- [ ] overview.md      — context, purpose, high-level architecture, tech stack
- [ ] components.md    — each module/service: responsibility, key files, dependencies
- [ ] data-model.md    — entities, stores, schema/migrations, relationships
- [ ] integrations.md  — external systems and internal service-to-service calls
- [ ] deployment.md    — build, environments, CI/CD, runtime topology   (if relevant)
- [ ] diagrams.md      — Mermaid: context, component, key sequences, ERD

### Functional / domain (docs/functional/)        (only if user-facing / domain-heavy)
- [ ] domain.md        — domain concepts, business rules, glossary
- [ ] flows.md         — primary user/business flows end-to-end
```

- Trim anything the app doesn't warrant; add anything specific it needs.
- Ask: **"This is the documentation map for {scope}. Confirm it before I start writing."**
- **Stop. Do not write documentation until the user confirms the map.**

---

## Isolation setup (standalone mode only)

If running **inside `incu-way-init`**, skip this — write into the existing init branch.

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
git switch -c docs/{slug}
```

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/docs-{slug} -b docs/{slug} origin/develop
```

`{slug}` is `{kebab-scope}` (e.g. `architecture`, `payments-module`). All docs are
written and committed inside the selected working location.

---

## Phase 2 — Author the documentation

**Goal:** Write each confirmed document, grounded in the actual code.

### Authoring rules (non-negotiable)

- **Traceable.** Every non-trivial claim points to its source — `path/to/file.ext:line`,
  a module, or a config key. A reader must be able to verify it in the code.
- **No invention.** Document what the code does, not what it "should" do. If behavior is
  unclear, write it under **Open questions / to verify** — never guess.
- **Conflicts get recorded, not resolved silently.** If two parts of the code (or the
  code and an existing doc) contradict each other, note the contradiction explicitly.
- **Concise prose.** Short, direct sentences. No filler. Bullets and tables over
  paragraphs where they read better.
- **Refresh = reconcile.** In refresh mode, update stale statements against the current
  code and flag what changed; do not blindly append.

### Suggested per-document shape

`docs/architecture/overview.md`:

```markdown
# Architecture overview — {app name}

## What it is
One paragraph: purpose and who uses it. (source: README / PRD / entry point)

## Tech stack
Languages, frameworks, datastores, infra — each with where it's configured.

## High-level architecture
The shape (layers / services / event-driven / …) and why, with a Mermaid context diagram.

## Module map
| Module | Responsibility | Key path | Talks to |
|--------|----------------|----------|----------|

## Cross-cutting concerns
Auth, config, logging/observability, error handling — where each lives.

## Open questions / to verify
- …
```

Mirror that traceable, table-first style across `components.md`, `data-model.md`,
`integrations.md`, and (when in scope) the functional docs. `data-model.md` should point
at the schema/migration files; `integrations.md` should name each external system and the
code that calls it.

---

## Phase 3 — Diagrams

Produce **Mermaid** diagrams in `docs/architecture/diagrams.md`, scaled to the app:

- **Context / container** — the system and its external actors and dependencies.
- **Component** — internal modules/services and their relationships.
- **Sequence** — the 1–3 most important end-to-end flows.
- **ERD** — the core data model, when there's a meaningful schema.

**Validate every diagram against the Mermaid parser before closing.** A diagram that
doesn't render is worse than none. Keep them readable — split an overcrowded diagram
into several focused ones.

---

## Gate 2 — Review

After the docs and diagrams are written:

- Provide the index (what was produced, where) and list the **Open questions / to
  verify** gathered across the docs.
- Say: **"Documentation ready under `docs/architecture/`{ and `docs/functional/`}. Open questions are listed for your input. Please review."**
- **Stop. Wait for user review before proceeding.**

If running inside `incu-way-init`, control returns to the init flow at its Gate 2 — the
docs are reviewed there and ship with the init PR. The standalone PR step below is skipped.

---

## Phase 4 — PR (standalone mode only)

Suggest invoking `incu-way-prepare-pr` to push `docs/{slug}` and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: docs({slug}): document {scope}
```

**PR body must include:**
- **Scope:** what was documented and at what depth.
- **Index:** links to each doc produced/updated.
- **Open questions:** the unresolved items needing team input.

Once opened, share the PR URL. **Stop. Do not merge until the user approves.**

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Map proposed | "This is the documentation map for {scope}. Confirm it before I start writing." | User confirms |
| 2 | Docs written | "Documentation ready under `docs/architecture/`. Please review." | User review |
| 3 | (standalone) Reviewed | Suggest `incu-way-prepare-pr` for PR `docs/{slug} → develop`; share URL once user runs it | User approves PR |

---

## What gets produced

```
docs/
  architecture/
    overview.md        # context, stack, high-level architecture
    components.md       # module/service breakdown
    data-model.md       # entities, stores, schema
    integrations.md     # external + internal integrations
    deployment.md       # build, environments, CI/CD, topology   (if relevant)
    diagrams.md         # validated Mermaid diagrams
  functional/           # only when user-facing / domain-heavy
    domain.md           # domain concepts + glossary
    flows.md            # primary flows end-to-end
```

---

## What NOT to do

- Do not write documentation before Gate 1 confirms the map.
- Do not invent behavior, structure, or intent. Anything not verifiable in the code goes
  under "Open questions / to verify".
- Do not make untraceable claims — every non-trivial statement points to a file/module/key.
- Do not close a diagram that fails to render in the Mermaid parser.
- Do not open a separate PR when invoked by `incu-way-init` — the docs ship with the init PR.
- Do not write directly to `develop` or `main` in standalone mode — use the `docs/{slug}` branch.
