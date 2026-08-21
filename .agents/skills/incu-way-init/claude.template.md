# CLAUDE.md — Template

> **How to use this template:**
> 1. Prefer running the `incu-way-init` skill — it copies and fills this template
>    automatically from the detected stack, scaffolds `docs/` and `.ways/`, and (for
>    an existing application) documents the architecture. Use the manual steps below only
>    for a quick start.
> 2. Copy this file as `CLAUDE.md` into the root of the new project.
> 3. Complete all sections marked with `[TODO: ...]`.
> 4. Remove the sections that don't apply to the project.
> 5. Delete this instructions block.
>
> The **Security**, **Work isolation**, **Development workflow**, and **Bug workflow** sections are mandatory and must not be modified — they are the core of the structured development workflow.

---

# CLAUDE.md

Instructions for Claude Code when working in this repository.

## About the project

[TODO: description of the product, who it's for, what problem it solves. Mention the main docs Claude should read before working (PRD.md, docs/, etc.).]

Read before working: `PRD.md`, the architecture docs in `docs/architecture/` (and
`docs/functional/` if present). If those don't exist yet, generate them with the
`incu-way-docs` skill.

## Stack

[TODO: list languages, frameworks, main libraries, and constraints. Examples:]

- **Language:** strict TypeScript (`"strict": true`) / Python / Go
- **Framework:** Next.js 15 (App Router) / NestJS / FastAPI
- **Database:** Postgres / MySQL / MongoDB + ORM used
- **Testing:** Vitest + Playwright / Jest + Cypress / pytest
- **Package manager:** pnpm / npm / yarn / uv

Do not add additional dependencies without explicit justification.

## Folder structure

[TODO: target directory structure of the project. Include comments about the purpose of each main folder.]

```
[structure here]
/docs
  /architecture   # Architecture & diagrams (incu-way-docs) — keep in sync with the code
  /functional     # Domain/functional docs (if the app is user-facing)
  /prds           # Feature PRDs (incu-way-development)
  /bugs           # Bug reports (incu-way-bugs)
  /security       # Remediation records (snyk-remediation)
/tests
  /unit
  /e2e
```

Never delete docs under `/docs`.

## Code conventions

[TODO: complete or adjust according to the project's language/framework.]

- **Naming:** camelCase for variables/functions, PascalCase for classes/components, snake_case in the DB.
- **Errors:** never swallow errors with an empty catch. Use a wrapper that returns `Result<T, Error>` or that throws exceptions with context.
- **Imports:** use the configured path aliases. No relative paths with `../../../`.
- **No `any`:** prefer strict types and explicit narrowing.
- **Comments:** only when the "why" isn't obvious from the code. Do NOT document the "what".
- [TODO: additional project conventions]

## Useful commands

[TODO: the project's main commands.]

```bash
# Development
[dev command]

# Build
[build command]

# Tests
[unit test command]
[e2e test command]

# Lint + typecheck
[lint command]
[typecheck command]

# Database (if applicable)
[migrate command]
[seed command]
```

## Environment variables

See `.env.example`. Never commit `.env.local` or files with real credentials.

[TODO: critical variables to highlight, especially which ones are safe for the client and which are server-side only.]

Universal rule: secret keys (API keys, service tokens, DB passwords) are **never** exposed in the client or in logs.

## Security (MANDATORY)

When vulnerabilities are detected (SAST, SCA, or any other source), **always** invoke the `snyk-remediation` skill before applying any fix. The skill manages the complete process: scan → triage → isolated branch → fix → re-scan → PR.

**Do not apply security fixes directly without going through the skill.**

## Work isolation first (UNIVERSAL RULE)

**All work — features, bugs, security fixes, any change — starts by choosing an isolation approach with the user before touching a single file.**

Always ask:

> Do you want me to work on a new branch in the current checkout, or to create a separate git worktree?

Use exactly the option the user picks.
Stop after asking; do not create a branch or worktree until the user chooses one.

If the current checkout has uncommitted changes, stop and ask before switching branch or creating a worktree.

### Option A — Branch in the current checkout

```bash
# From the repo root
git switch develop
git pull --ff-only
git switch -c {type}/{slug}
```

All work happens on that branch. Never create files in `develop` or `main` with the intention of moving them later.

### Option B — Separate worktree

Create worktrees only under `.worktrees/`. Do not ask the user for a path.

```bash
# From the repo root
git fetch origin develop
mkdir -p .worktrees
git worktree add .worktrees/{slug} -b {type}/{slug} origin/develop
```

All work happens inside that worktree. Never create files in `develop` or `main` with the intention of moving them later. This applies to docs, code, configuration — everything.

## Committing and PRs (UNIVERSAL RULE)

**No skill or flow commits, pushes, or opens a PR on its own.** `incu-way-prepare-pr` is the only skill that runs `git add`, `git commit`, `git push`, or `gh pr create`, and it only runs when the user explicitly asks for it (by name, or "commit this", "push this", "prepare the PR"). Every other flow just writes files and, at natural checkpoints, tells the user it's ready and suggests invoking `incu-way-prepare-pr` — it never runs those git commands itself.

## Development workflow (MANDATORY for any new feature)

For any new functionality or significant change, **always** invoke the `incu-way-development` skill before writing a single line of code. The skill defines a process with explicit approval gates:

1. **Phase 0** — Orientation: read PRD.md and docs/
2. **Isolation** — Ask whether to use a branch in the current checkout or a separate worktree **before writing anything**
3. **Phase 1** — Write the PRD in `docs/prds/{slug}/PRD.md` (in the chosen work location) → **wait for approval**
4. **Phase 2** — Implementation plan in `docs/prds/{slug}/PLAN.md` (in the chosen work location) → **wait for approval**
5. **Phase 3** — Implementation (in the chosen work location)
6. **Phase 4** — Validation + testing guide → **wait for feedback**
7. **Phase 5** — PRs: `feat/{slug}` → `develop` → `main`, opened only when the user invokes `incu-way-prepare-pr`

**Never write code before the user approves the PRD (Gate 1).**

## Bug-fixing workflow (MANDATORY for any bug)

For any reported or discovered bug, **always** invoke the `incu-way-bugs` skill before writing a single line of fix code. The skill defines a process with one explicit approval gate:

1. **Isolation** — Ask whether to use a branch in the current checkout or a separate worktree **before writing anything**
2. **Phase 1** — Document in `docs/bugs/{id}-{slug}/BUG.md`
3. **Phase 2** — Analysis in `docs/bugs/{id}-{slug}/ANALYSIS.md`
4. **Phase 3** — Reproduction test that fails before the fix
5. **Phase 4** — Plan in `docs/bugs/{id}-{slug}/FIX_PLAN.md` → **wait for approval**
6. **Phase 5** — Implement (only what the plan says)
7. **Phase 6** — Validation + security scans
8. **Phase 7** — PR `fix/{slug}` → `develop`, opened only when the user invokes `incu-way-prepare-pr`

**Never write fix code before the user approves the FIX_PLAN.**

## Mandatory tests

[TODO: tests that absolutely must exist before considering any feature done. Think about:]

- Critical cases of the business domain
- Deduplication or idempotency cases if the system imports/processes data
- Access / authorization rules (who can read, who can write)
- API contracts or exports that other systems consume

Before marking a phase as done, always run the full suite.

## Sensitive data

[TODO: complete if the project handles PII or other sensitive data.]

Universal principles:
- Never log PII (emails, phone numbers, ID documents) in production.
- Explicit confirmation when exporting sensitive data.
- In the UI, hide sensitive fields by default behind a user action.

## Don't

[TODO: project-specific constraints.]

Universal constraints:
- Don't mix business logic with presentation logic.
- Don't use authorization/RLS bypasses in code that runs on the client side.
- Don't include secrets in client bundles.
- Don't `git push --force` to `main` or `develop`.
- Don't skip git hooks (`--no-verify`) without an explicit reason.
- Don't commit, push, or open a PR without the user explicitly asking — invoke `incu-way-prepare-pr` only when they ask for it, and only suggest it otherwise.

## When in doubt

If a decision isn't covered in `PRD.md` or `docs/`, **ask** instead of improvising. The user's input matters.
