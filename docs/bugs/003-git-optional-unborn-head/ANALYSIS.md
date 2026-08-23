# Analysis — Git required (and required to have a commit) to start a session

## Root cause

Two independent places treat git as mandatory for **every** session, including
`.currentCheckout`, which never touches a branch or a worktree:

1. **`GitService.resolveBaseBranch()`** (`Sources/ZeroCore/Git/GitService.swift:42`) reads the
   current branch with `git rev-parse --abbrev-ref HEAD`. On an unborn `HEAD` (repo initialized,
   no commits) that command exits **128** — there is no commit for `HEAD` to resolve to. Verified
   directly:

   ```
   $ git init -q . && git rev-parse --abbrev-ref HEAD
   fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.
   exit=128
   $ git branch --show-current
   main
   exit=0
   ```

   `git branch --show-current` (git ≥ 2.22) reads `HEAD`'s symbolic ref instead of resolving it,
   so it answers correctly on an unborn branch, and prints nothing with exit 0 when detached.

   `SessionRuntime.create` calls `resolveBaseBranch()` for `.currentCheckout`
   (`Sources/ZeroCore/Session/SessionRuntime.swift:238`) purely to get a **display label** that is
   persisted as `Session.branch`. The failure aborts creation before the CLI is ever launched.

2. **`GitService.init`** (`GitService.swift:20`) throws `notARepository` when `.git` is absent, and
   `create` builds a `GitService` unconditionally (`SessionRuntime.swift:223`) — so a plain folder
   with no git at all cannot start a session either. This is the same defect as (1) one step
   earlier: git is a hard dependency of a code path that does not need it.

The permission mode (Auto) is incidental — `permissionArguments` runs *after* the git work.

## Affected code

| Location | Role |
|---|---|
| `Sources/ZeroCore/Git/GitService.swift:41-48` | `resolveBaseBranch()` — the failing command |
| `Sources/ZeroCore/Git/GitService.swift:17-24` | `init` — hard `.git` requirement |
| `Sources/ZeroCore/Session/SessionRuntime.swift:220-247` | `create` — builds `GitService` unconditionally, resolves branch for `.currentCheckout` |
| `Sources/ZeroCore/Session/SessionRuntime.swift:387-392` | `resume` — builds `GitService` for a value it never uses |
| `Sources/ZeroCore/Session/SessionRuntime.swift:104,132,140` | `gitService` stored property — never read by any instance method |

Callers of the two git-mandatory paths: `resolveBaseBranch()` has exactly two — `create`
(`.currentCheckout`) and `createWorktree` (as the worktree base). Fixing it inside `GitService`
therefore fixes both, and is a smaller diff than guarding either caller.

## Two related findings, same root

- **`resume` needs no git.** `gitService` is stored on the runtime but read by no instance method
  (only `create`'s rollback uses it, via its local). `resume` builds one from
  `worktree.deletingLastPathComponent().deletingLastPathComponent()`
  (`SessionRuntime.swift:381`) — the grandparent of the worktree. For `.isolatedWorktree`
  (`<repo>/.worktrees/<name>`) that happens to be the repo root; for `.currentCheckout` the
  worktree *is* the repo, so it points at the repo's **grandparent** directory. Resuming an
  in-place session in a repo whose grandparent is not a git repo throws `gitError` for a service
  nobody consults. Removing the unused property removes this failure rather than repairing it.
- **`isolatedWorktree` genuinely needs git**, and a commit: `git worktree add -b … <base>` cannot
  branch from an unborn `HEAD`. That must keep failing — with git's own message — and stays git's
  answer to give, not a precondition we duplicate.

## Impact

Every session in (a) a repo with no commits, or (b) a folder with no `.git`, when the workspace is
"This checkout" — the default. No data at risk: creation fails before any process launches, before
anything is persisted, and no worktree is created. Resume of in-place sessions is affected by the
same class of failure (see above).

## Reproduction path

`GitService.resolveBaseBranch()` against a repo created with `git init` and no commit throws
`GitError.commandFailed(command: "rev-parse --abbrev-ref HEAD", exitCode: 128, …)`. This is
directly testable at the `GitService` level — see the reproduction test in
`Tests/ZeroCoreTests/Git/GitServiceTests.swift`. The no-git path is testable at the same level
(`GitService(repositoryPath:)` on a plain directory).

## Tooling note — security scans

`snyk_code_scan` / `snyk_sca_scan` MCP tools and `run-sonnar.sh` are not available in this
environment (this repo has no `run-sonnar.sh`, and no Snyk MCP tools are exposed to the session).
The Phase 6 scans therefore cannot be run and must not be reported as clean; validation will rely
on `swift build` + `swift test`. Ask the user whether to install/configure them or proceed with
the available validation only.
