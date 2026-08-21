---
name: incu-way-init
version: 0.1.0
description: Use when adopting incu-way in a repository for the first time — to bootstrap the project so the development, bug, and security flows have what they need. Detects greenfield (new, empty repo) vs brownfield (existing application — the common case), scaffolds CLAUDE.md, the docs/ tree, the branch model, and .ways/, and drives the architectural/functional documentation of the existing code. Also use to re-initialize or refresh a project that already uses incu-way.
---

# Repository Initialization Process

A gate-driven workflow for onboarding a repository into incu-way. It prepares the
ground the other skills assume: a filled `CLAUDE.md`, a `PRD.md`, the `docs/` tree,
the `develop`/`main` branch model, and the `.ways/` directory. For an **existing
application** (brownfield — the common case) it also drives the **architectural and
functional documentation** so that humans and the incu-way flows actually understand
what the repo contains.

This is a **bootstrap flow**, not a work-item flow. It does **not** create a
`.ways/state.json` (that model is for `feature` / `bug` / `security`
work — see the ways/v1alpha1 state contract, shipped as the always-on `state-contract` rule). Instead,
**this skill creates the `.ways/` directory** the work-item flows later populate.

---

## Phase 0 — Orientation and mode detection

**Goal:** Decide whether this is a greenfield or a brownfield repository, and whether
incu-way is already (partially) set up. Do not write anything yet.

### Detection checklist

Run a read-only survey of the repo root:

```bash
git -C . rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo at all?
git log --oneline -1 2>/dev/null                        # any commits yet?
git branch -a                                           # does develop/main exist?
ls -A                                                    # what is at the root?
```

Then look for the signals below.

1. **Application code present?** Source directories (`src/`, `app/`, `lib/`, `pkg/`, …)
   with real, non-boilerplate code.
2. **Dependency/build manifests?** `package.json`, `pnpm-lock.yaml`, `pom.xml`,
   `build.gradle`, `go.mod`, `requirements.txt`/`pyproject.toml`, `Cargo.toml`,
   `*.csproj`, `Gemfile`, etc.
3. **Git history?** Zero commits / empty tree vs. a real history.
4. **incu-way already present?** A `CLAUDE.md` that references the incu-way flows, a
   `.ways/` directory, or `docs/architecture/`.
5. **Branch model?** Whether `main` and `develop` already exist.

### Classify the repo

- **Greenfield** — empty or near-empty (no application code yet; maybe just a README
  or license). The work is to capture **intent**: product vision and the architecture
  the team plans to build.
- **Brownfield** — an existing application with code and history (**assume this is the
  default**). The work is to **reverse-engineer understanding**: document the
  architecture and, when warranted, the functional behavior of what already exists.
- **Already initialized** — incu-way structure is present. Switch to **refresh mode**:
  fill gaps, update stale sections, and (for brownfield) re-run the documentation pass.

### Phase 0 exit criteria

Before Gate 1, Claude should be able to state:
- whether the repo is greenfield, brownfield, or already initialized
- the detected stack (languages, frameworks, package manager, test runner, build tool)
  — for brownfield, derived from the manifests and directory layout, not assumed
- whether `main` and `develop` exist (and whether git is initialized at all)
- which incu-way pieces already exist and which are missing
- the proposed initialization plan (files to create, branch strategy, documentation depth)

Do not guess the stack or the product purpose. If the manifests are ambiguous or the
repo's intent is unclear, note it as an open question for Gate 1 rather than inventing it.

---

## Gate 1 — Confirm mode and scope

Present the detection result and the proposed plan, then confirm with the user.

Show a short summary:

```markdown
## Initialization plan

- **Mode:** greenfield | brownfield | refresh
- **Detected stack:** {languages / frameworks / package manager / test runner}
- **Branch model:** {exists: main, develop} | {will create: main, develop}
- **Will create / update:**
  - CLAUDE.md (from template, filled with the detected stack)
  - PRD.md (root) — {product vision (greenfield) | reverse-engineered overview (brownfield)}
  - docs/ tree: prds/, bugs/, security/, architecture/
  - .ways/ (work-item state.json lives here later)
- **Documentation depth (brownfield):** {structural only | architecture | architecture + functional}
- **Open questions:** {anything ambiguous about stack or product intent}
```

- Ask: **"This is the initialization plan. Confirm the mode and the documentation depth before I create anything."**
- **Stop. Do not proceed until the user confirms the mode and scope.**

Do not treat repo detection alone as approval to scaffold. Gate 1 sets the mode and the
documentation depth.

---

## Isolation setup (immediately after Gate 1)

**Before writing any file**, establish the branch model and ask the user how they want
to isolate the init work:

> Do you want me to work in a new branch in the current checkout, or create a separate git worktree?

Use the user's answer exactly.
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branches or creating a worktree.

### Greenfield with no git yet

Use a branch in the current checkout unless the user explicitly asks for a separate
worktree after git is initialized. This repo has no commits yet, so `main`/`develop`
can't exist without one — ask first: **"This repo has no commits yet. OK if I create an
empty initial commit to establish `main`?"** Only after the user confirms:

```bash
git init
git checkout -b main
git commit --allow-empty -m "chore: initial commit"
git checkout -b develop
git checkout -b chore/incu-way-init
```

### Brownfield (git already exists)

If `develop` is missing, it needs to be created from `main` (this is a repo-wide
decision — confirm at Gate 1 if it wasn't already) and pushed so it exists on the
remote. Ask first: **"`develop` doesn't exist yet. OK if I create it from `main` and
push it?"** Only after the user confirms:

```bash
git checkout main && git checkout -b develop && git push -u origin develop   # only if develop is missing
```

### Option A — Branch in current checkout

```bash
# Run from the repo root
git switch develop
git pull --ff-only
git switch -c chore/incu-way-init
```

All subsequent work — CLAUDE.md, docs, the `.ways/` scaffold, commits — happens
on this branch in the current checkout. Never write directly to `develop` or `main`.

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# Run from the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/incu-way-init -b chore/incu-way-init origin/develop
```

All subsequent work — CLAUDE.md, docs, the `.ways/` scaffold, commits — happens
exclusively inside this worktree. Never write directly to `develop` or `main`.

---

## Phase 2 — Scaffold the incu-way structure

**Goal:** Create the files and directories the incu-way flows assume, filled with real,
detected information (not placeholders, where the repo gives the answer).

### 2.1 — `CLAUDE.md`

Copy this skill's bundled `claude.template.md` (it sits next to this SKILL.md, so it
travels with the skill on `ways add`) to the repo root as `CLAUDE.md` and **fill every
`[TODO: ...]`** from what Phase 0 detected:

- **About the project** — for brownfield, derive from README, manifests, and code; for
  greenfield, from the user's vision captured at Gate 1.
- **Stack** — languages, frameworks, DB, testing, package manager (detected).
- **Folder structure** — the real top-level layout with one-line purposes.
- **Code conventions** — infer from existing config (`.eslintrc`, `.editorconfig`,
  `tsconfig.json`, linters, formatters) for brownfield; from the template defaults for
  greenfield.
- **Useful commands** — read them from the manifest's scripts (`package.json` `scripts`,
  `Makefile`, `pom.xml`, etc.). Do **not** invent commands that don't exist.
- Keep the mandatory **Security**, **Worktree**, **Development workflow**, and **Bug
  workflow** sections exactly as the template defines them.

Anything you cannot derive, leave as an explicit `[TODO: ...]` and list it at Gate 2 —
do not fabricate.

### 2.2 — `PRD.md` (root)

The incu-way flows read `PRD.md` first in their Phase 0. Create it:

- **Greenfield:** capture the product vision agreed at Gate 1 — problem, target users,
  goals, non-goals, the intended high-level architecture.
- **Brownfield:** a **reverse-engineered product overview** — what the application does
  today, for whom, and its main capabilities, traceable to the code. If `incu-way-docs`
  is in scope (see Phase 3) this can be a short pointer to `docs/architecture/` and the
  functional docs, kept deliberately thin.

### 2.3 — `docs/` tree and `.ways/`

Create the directory structure the flows write into:

```
docs/
  prds/          # incu-way-development writes here
  bugs/          # incu-way-bugs writes here
  security/      # snyk-remediation writes here
  architecture/  # incu-way-docs writes here (brownfield)
.ways/       # work-item state.json lands here later (add a .gitkeep)
```

Add `.gitkeep` to the empty directories so they are committed. Do **not** create a
`.ways/state.json` here — it belongs to the work-item flows.

> `.ways/` is the canonical root for way state (`ways/v1alpha1`). If the project also uses
> the `ways` CLI, that tool keeps a **cache** under `.ways/cache/` — see repo hygiene below.

### 2.4 — Repo hygiene (only when needed)

- Add `.worktrees/` to `.gitignore` if it isn't already
  ignored and lives inside the repo.
- **`.ways/` gitignore rule.** `.ways/state.json` **must stay tracked** (resume-by-branch
  and the board depend on it being committed via `incu-way-prepare-pr`). If the `ways` CLI
  is in use, ignore only its cache — add `.ways/cache/` (not the whole `.ways/`) to
  `.gitignore`. Never blanket-ignore `.ways/`.
- If the project uses the SonarQube scan referenced by the flows, note where
  `run-sonar.sh` lives or that it is still TODO — do not fabricate the script.

Tell the user the scaffold is ready and suggest invoking `incu-way-prepare-pr` to commit it — do not commit it yourself:

```
Suggested message: chore(incu-way-init): scaffold CLAUDE.md, docs/ tree and .ways/
```

---

## Phase 3 — Documentation of the application

**Goal:** Produce the architectural (and, if warranted, functional) documentation that
lets humans and the incu-way flows understand the application.

### Brownfield — invoke `incu-way-docs`

If the documentation depth agreed at Gate 1 is **architecture** or **architecture +
functional**, hand off to the **`incu-way-docs`** skill, instructing it to write into the
**current init branch/worktree** (no separate PR — its output ships with this init PR).
`incu-way-docs` produces, scaled to the app:

- `docs/architecture/` — overview, components, data model, integrations, deployment/ops
- functional/domain docs and a glossary (when the app is user-facing or domain-heavy)
- Mermaid diagrams (validated)

If the agreed depth is **structural only**, skip the deep pass — the `CLAUDE.md` folder
structure + `PRD.md` overview are enough for now. Note in `PRD.md` that the deep
documentation is deferred and can be generated later with `incu-way-docs`.

### Greenfield — capture intended architecture

There is no code to reverse-engineer. Instead, record **intent** in
`docs/architecture/overview.md`: the planned architecture, major components, key
technology choices and the reasoning (ADR-style). Keep it lightweight; it will evolve as
the code is written through `incu-way-development`.

---

## Gate 2 — Review the initialization

After scaffolding (and documentation, when in scope):

- Summarize what was created/updated and list every remaining `[TODO: ...]` in
  `CLAUDE.md` and any open questions.
- Say: **"Initialization complete on `chore/incu-way-init`. CLAUDE.md, PRD.md, the docs/ tree and .ways/ are in place{, plus the architecture/functional docs}. Please review before I open the PR."**
- **Stop. Do not open the PR until the user approves.**

---

## Phase 4 — Merge via Pull Request

**Goal:** Land the initialization on `develop` (and then `main`) through a reviewed PR.
Never merge directly.

### PR

After Gate 2 approval, suggest invoking `incu-way-prepare-pr` to push `chore/incu-way-init` (including the first push of `main`/`develop` if the repo had no remote/history yet) and open the PR. Do not push or run `gh pr create` yourself.

**Suggested PR title/body for `incu-way-prepare-pr` to use:**

```
Title: chore: initialize incu-way
```

**PR body must include:**
- **Mode:** greenfield / brownfield / refresh.
- **Created/updated:** CLAUDE.md, PRD.md, docs/ tree, .ways/, and (if any)
  the architecture/functional docs with links.
- **Open items:** remaining `[TODO: ...]` and open questions for the team.

Once opened, share the PR URL with the user. **Stop. Do not merge until the user approves.**

If the team gates on `main` too, open the follow-up PR `develop → main` after the first
is merged, same as the development flow.

---

## Quick reference — gates

| Gate | Trigger | What to say | Block until |
|------|---------|-------------|-------------|
| 1 | Mode + plan detected | "This is the initialization plan. Confirm the mode and documentation depth." | User confirms |
| 2 | Scaffold (+ docs) ready | "Initialization complete on `chore/incu-way-init`. Please review before I open the PR." | User approves |
| 3 | Reviewed | Suggest `incu-way-prepare-pr` for PR `chore/incu-way-init → develop`; share URL once user runs it | User approves PR |

---

## What NOT to do

The phase-level rules above are authoritative; the one point not stated elsewhere:

- The greenfield/brownfield bootstrap commands are the **only** exception to the no-auto-commit
  rule, and even those require asking first — everything else (the scaffold commit, the PR) only
  happens via `incu-way-prepare-pr`.
