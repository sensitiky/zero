---
name: incu-way-prepare-pr
version: 0.1.0
description: The only skill in this repo that runs `git add`, `git commit`, `git push`, or `gh pr create`. Invoke ONLY when the user explicitly asks to commit, push, or open/prepare a PR (e.g. "commit this", "commit progress", "push this branch", "prepare the PR", "open the PR"). No other incu-way skill may invoke this automatically or run those git commands itself — they may only suggest it to the user.
---

# Prepare PR / Commit Changes

The single place where incu-way work gets persisted to git. Every other flow in this
repo only **writes files** and **suggests** running this skill at natural checkpoints —
none of them commit, push, or open a PR on their own. This list is deliberately not
enumerated here: any current or future incu-way flow follows the same rule, so there is
nothing to keep in sync when a skill is added, renamed, or removed.

**The real gate against self-invocation is the frontmatter `description` above**, not
this paragraph — skill matching happens off that description before any body text is
read, so "Invoke ONLY when the user explicitly asks" has to live there to actually work.
This body is a second line of defense for whoever ends up reading this file directly: if
you are a caller skill, don't invoke this skill yourself — say something like *"This
checkpoint is ready. Run `incu-way-prepare-pr` (or ask me to) when you want to commit
it."* and stop there.

---

## Step 1 — Locate context

```bash
git branch --show-current
```

Derive `{slug}` the same way the flows do (branch without its `feat/` | `fix/` |
`fix/security-` | `chore/` | `docs/` | `assess/` prefix). If
`.ways/state.json` exists, read it
(do not write to it yet) to know the
`flow`, `phase`, and which gate/document this checkpoint corresponds to. If it doesn't
exist (e.g. assessment/documentation flows with no item file, or a plain ad hoc
"commit this" request), proceed without it.

## Step 2 — Show exactly what would be committed

```bash
git status --short
git diff --stat
git diff --stat --staged
```

Present this to the user before touching anything. If nothing is staged or changed,
say so and stop — there is nothing to commit.

## Step 3 — Propose a commit message

Don't guess a generic message — the calling flow's own SKILL.md already documents the
exact commit-message format for its phase (look for a "commit message format" /
"suggested commit message" section near the checkpoint the user is at, or infer the
type from the branch prefix: `feat/` → `feat({slug}): ...`, `fix/` → `fix({slug}): ...`,
`fix/security-` → `fix(security): ...`, `chore/` → `chore(...)`, `docs/` → `docs({slug}): ...`,
`assess/` → `assess({slug}): ...`). If no convention is evident, ask the user.

If the state file `.ways/state.json` changed alongside other files, it is
committed **together with** those files in the same commit — never in a separate,
unannounced commit.

If more than one logical unit of work is staged/dirty (e.g. two unrelated checkpoints),
say so and ask whether to split into separate commits rather than bundling them
silently.

### Gate — commit confirmation

Say: **"About to commit: {file list}. Message: `{proposed message}`. Confirm before I run `git add` / `git commit`."**

**Stop. Do not run `git add` or `git commit` until the user confirms.**

Only after explicit confirmation, stage exactly the reviewed files and commit.

## Step 4 — Push and PR (only if the user asks for this too)

Do not assume a commit implies the user also wants to push or open a PR. Ask:

> Do you also want me to push `{branch}` and open a PR to `{base}`?

If yes, draft the title/body using the same template the calling flow already defines
for its PR phase (summary, links to the relevant docs, the validation checklist, etc.
— see the flow's own SKILL.md for the exact body it expects). Show the drafted
title/body to the user.

### Gate — push/PR confirmation

Say: **"About to push `{branch}` and open a PR: `{base}` ← `{branch}`, title `{title}`. Confirm before I push and open it."**

**Stop. Do not run `git push` or `gh pr create` until the user confirms.**

Only after explicit confirmation:

```bash
git push -u origin {branch}
gh pr create --base {base} --head {branch} --title "{title}" --body "{body}"
```

Share the resulting PR URL with the user.

## Step 5 — Update state (if a state file exists)

If `.ways/state.json` exists and a PR was just opened, set the matching
`gates[].url` to the PR link as part of the work already confirmed in Step 4 — this is
metadata about the action just taken, not a new unannounced action, so it does not need
its own separate gate. If the PR gate should now read `passed` (e.g. it was merged
externally and the user is only recording that here), update its `status` too.

---

## What NOT to do

- Do not invoke yourself automatically from within another skill's flow — you only run
  when the user explicitly asks in the current turn.
- Do not commit, push, or open a PR without the explicit confirmation gates above, even
  if the user invoked you directly — invoking this skill starts the conversation, it is
  not itself the confirmation.
- Do not bundle unrelated changes into one commit without calling it out first.
- Do not merge PRs. Opening a PR is in scope; merging is always a separate, explicit
  user action outside this skill.
