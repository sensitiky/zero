# State contract — `.ways/state.json` (ways/v1alpha1)

Canonical, agent-facing contract for the state file the gated flows (`feature` / `bug` /
`security`) read and write. This rule travels with the way (placed as an **always-on** rule
on `ways add`), so any installed flow knows how to generate and resume its state — no
in-repo doc is required.

> **Upstream standard.** Conforms to the **ways state standard** (`ways/v1alpha1`) — the
> normative source is `state.schema.json` (`schemas/ways/v1alpha1/`) and
> `docs/standards/state-files.md` in the `ways` package. `ways validate` enforces the schema.
> This rule is the human/agent rendering of that contract; where they differ, the schema wins.

## What it is and who reads it

A state file lets a flow know **where it is** (so it can resume) and lets tooling see
**what's going on**. There is exactly **one** state file per worktree/branch — it *is* the
state for that worktree.

## Where it lives — one file per worktree/branch

Canonical root is **`.ways/`**:

```
<worktree>/.ways/state.json     # working in a separate worktree
<repo-root>/.ways/state.json    # working in the current checkout
```

The state lives **only** at `.ways/state.json` — one canonical location, no legacy paths.

Document paths inside the JSON are **relative to the root** where the file lives. A worktree
is on exactly one branch working exactly one item, so a single `state.json` describes "what
I'm working on here". The **`branch` field is the item's identity** — it confirms the file is
its own on startup and disambiguates stale copies.

## Session startup (resuming) — `branch` disambiguates

Before doing anything, locate yourself:

```bash
git branch --show-current            # e.g. feat/003-contact-export
cat .ways/state.json 2>/dev/null     # the single state file, if any
```

- **`state.json` exists and its `branch` matches the current branch** → read it; report the
  current phase, last `done` step, next `todo` step, and pending gates; resume from there.
- **`state.json` exists but its `branch` does not match** (stale, inherited from a merged
  item) **or it does not exist** → no active work on this branch → cold start (Phase 0); the
  file is created/overwritten at `.ways/state.json` after the isolation setup.
- **On `develop`/`main` (root)** → the branch maps to no active item → it's not a work session.

## Schema (schemaVersion 2)

Required: `schemaVersion`, `flow`, `slug`, `branch`, `phase`.

```jsonc
{
  "schemaVersion": 2,
  "updatedAt": "2026-06-15T12:30:00Z",   // ISO-8601 UTC, refreshed on every change
  "flow": "feature",                      // "feature" | "bug" | "security" (or a namespaced extension)
  "way": "incu/dev",                      // OPTIONAL — the way artifact that produced this state
  "wayVersion": "1.1.0",                  // OPTIONAL — that way's version (semver, or "" if unknown)
  "discipline": "development",            // OPTIONAL — the way's SDLC discipline
  "slug": "003-contact-export",           // kebab-id of the item
  "branch": "feat/003-contact-export",    // git branch — the item's IDENTITY
  "worktree": ".worktrees/003-contact-export", // OPTIONAL — path relative to repo root ("" for root checkout)
  "isolationType": "worktree",            // OPTIONAL — "branch" | "worktree" | "noIsolation"
  "title": "Contact export",              // human-readable title
  "ticket": "PROJ-1234",                 // ticket id, or null
  "lastPhase": "prd",                     // OPTIONAL — phase before the current one ("" at start)
  "phase": "implementation",              // current internal phase (see enums)
  "documents": [
    { "name": "PRD.md",  "path": "docs/prds/003-contact-export/PRD.md",  "status": "approved" },
    { "name": "PLAN.md", "path": "docs/prds/003-contact-export/PLAN.md", "status": "approved" },
    { "name": "TESTING.md", "path": "docs/prds/003-contact-export/TESTING.md", "status": "pending" }
  ],
  "gates": [
    { "id": "prd",  "label": "PRD review",  "status": "passed",  "at": "2026-06-15T11:00:00Z" },
    { "id": "plan", "label": "Plan review", "status": "passed",  "at": "2026-06-15T11:45:00Z" },
    { "id": "testing", "label": "User testing", "status": "pending", "at": null },
    { "id": "pr-develop", "label": "PR feat→develop", "status": "pending", "at": null, "url": "https://…/pull/42" }
  ],
  "steps": [                              // generated when the plan is closed (see below)
    { "id": "A1", "label": "Add export schema migration", "status": "done" },
    { "id": "A2", "label": "Export API endpoint",         "status": "in-progress" },
    { "id": "B1", "label": "Export button + modal (UI)",  "status": "todo" }
  ]
}
```

**Serialization.** UTF-8 JSON, 2-space indent, LF line endings, exactly one trailing newline,
and **keys emitted in a stable, defined order** (the order above). Stable ordering kills diff
churn and minimizes merge conflicts on the shared `state.json` path.

### Optional / generalization fields

Optional but recommended — they make the state reproducible and let tooling attribute and
group items across multiple ways without resolving each manifest:

- **`way`** — which packaged way produced the state (`incu/dev`, `incu/bugs`, …).
- **`wayVersion`** — that way's version (semver, or `""` when unknown).
- **`discipline`** — the producing way's SDLC discipline (`development`, `security`, …).
- **`worktree`** — worktree path relative to the repo root (`""` for the root checkout).
- **`isolationType`** — `branch` · `worktree` · `noIsolation` (run-in-place; a new flow then
  overwrites the current `state.json`).
- **`lastPhase`** — the phase before the current one (a valid `phase`, or `""` at the start);
  `phase` stays authoritative.
- **`ext`** — reserved free-form object for facts the core doesn't model; namespace your keys
  (`ext: { "incu": { … } }`). Also allowed on each `gates[]` / `steps[]` entry.

### Three orthogonal axes: `way` · `flow` · `discipline`

`way` = which packaged artifact runs (`incu/dev`); `flow` = which kind of gated process
(`feature` · `bug` · `security`); `discipline` = which SDLC stage (`development`). Orthogonal:
the same `flow` can ship in different `way`s; one `discipline` spans several `flow`s.

### Enums

Every enumerated field is a closed `enum` **or** a namespaced `<discipline>/<name>` extension
(pattern `^[a-z][a-z0-9-]*/[a-z][a-z0-9-]*$`, e.g. `qa/regression`). A bare unknown value (a
typo like `fature`) is invalid; extensions must be explicitly namespaced.

- **`flow`**: `feature` · `bug` · `security` — or a namespaced extension.
- **`phase`** (per flow; the schema enum is their union) — or a namespaced extension:
  - feature: `discovery` → `prd` → `plan` → `implementation` → `validation` → `pr-develop` → `pr-main` → `done`
  - bug: `discovery` → `document` → `analysis` → `reproduction` → `fix-plan` → `implementation` → `validation` → `pr` → `done`
  - security: `scan` → `findings` → `plan` → `implementation` → `validation` → `pr-develop` → `pr-main` → `done`
- **`documents[].status`**: `pending` · `draft` · `in-review` · `approved` · `done`
- **`gates[].status`**: `pending` · `passed`. PR gates (`pr-develop`, `pr-main`, `pr`) accept an
  optional **`url`**; they stay `pending` while the PR is open and become `passed` once merged.
  `at` is an ISO-8601 timestamp or `null`.
- **`steps[].status`**: `todo` · `in-progress` · `done` · `blocked`

## Lifecycle and git — written on every transition, committed only by the user

The state file is **written** (not committed) by the flow on each transition. **No flow ever
runs `git add`/`git commit`/`git push`/`gh pr create`** — persistence happens only when the
**user** explicitly invokes the `incu-way-prepare-pr` skill, which commits the state file
**together with** the docs/code of that transition, in the same commit.

- Merging `feat/{slug}` → `develop` → `main` **propagates** the file to those branches (no
  pre-merge cleanup — the merge is server-side). On `develop`/`main` it simply goes **stale**
  (describes the last item merged there) and is ignored for resume.
- A new worktree branched off `develop` **inherits** that stale `state.json`; the flow detects
  the `branch` mismatch, treats it as a cold start, and **overwrites** it with the new item
  after isolation setup.
- **Merge caveat.** Because every branch writes the same path, two PRs merging into `develop`
  in sequence can conflict on this one file. It's trivial: the copy on `develop` is stale and
  ignored either way — **take either side** (conventionally the incoming branch's). Stable key
  ordering keeps such conflicts minimal.

## When to write / update

Create the file **right after the isolation setup** at `.ways/state.json`, with `flow`,
`slug`, `branch`, the initial `phase`, the expected `documents` in `pending`, and the optional
`way`/`wayVersion`/`discipline`/`isolationType`. If a stale `state.json` is present (its
`branch` doesn't match), overwrite it.

On each transition update `updatedAt`, `phase` (and `lastPhase`), the relevant document's
`status`, and `gates[].status` when a gate is approved. **Write only — never commit.**

**Steps generation.** When the plan/fix-plan gate passes, translate the plan into the `steps`
array — one entry per actionable task, all `todo`. During implementation mark each
`in-progress` → `done` (or `blocked`). `steps` are what tooling shows as progress ("3/7") and
what the flow uses to report the "next step".

## `.gitignore` note

`.ways/state.json` **must stay tracked** (resume-by-branch depends on it being committed via
`incu-way-prepare-pr`). If the `ways` CLI is in use, ignore only its cache — add `.ways/cache/`
to `.gitignore`, **never** blanket-ignore `.ways/`.
