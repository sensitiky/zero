# Fix Plan — Git optional for in-place sessions; branch resolvable without a commit

## Branch / worktree
Branch: `fix/003-git-optional-unborn-head`
Isolation mode: separate worktree — `../worktrees/fix-003-git-optional-unborn-head`

## Root cause (one line)
`GitService` resolves the current branch with `rev-parse --abbrev-ref HEAD`, which needs a commit,
and `SessionRuntime.create` requires a `GitService` at all — for a `.currentCheckout` session that
only wants a branch **label**.

## Fix approach

**1. `GitService.resolveBaseBranch()` — one command swap** (`GitService.swift:42`)

```diff
-let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
+let output = try runGit(["branch", "--show-current"])
```

`branch --show-current` reads `HEAD`'s symbolic ref instead of resolving it: correct on an unborn
branch, empty (exit 0) when detached. The existing `guard` already turns empty into
`cannotResolveBranch`, so detached `HEAD` keeps throwing — the `HEAD != branch` half of that guard
becomes dead and goes. Both callers (`create` and `createWorktree`) are fixed by this one change.

**2. Git becomes optional in `SessionRuntime.create`** (`SessionRuntime.swift:220-247`)

- `let gitService = try? GitService(repositoryPath: config.repository)` — `nil` means "not a
  repository", which is a legitimate place to run an agent, not an error.
- `.currentCheckout`: branch is a display label, so it degrades instead of aborting —
  `(try? await gitService?.resolveBaseBranch()) ?? "—"`. This also unblocks a **detached HEAD**
  checkout, which fails today for the same reason.
- `.isolatedWorktree`: still requires git — `guard let gitService else { throw .gitError(…) }`.
  A worktree from an unborn `HEAD` keeps failing with git's own message; that is git's answer to
  give, not a precondition we restate.

**3. Delete the unused `gitService` from the runtime** (`SessionRuntime.swift:104,132,140`)

No instance method reads it (`create`'s rollback uses its own local). Removing the stored property
and its `init` parameter also removes `resume`'s `GitService` construction
(`SessionRuntime.swift:387-392`), which was built from the worktree's **grandparent** — wrong for
in-place sessions, and today a spurious `gitError` when resuming one. Deleting the dependency fixes
that without adding a code path for it.

**4. Tests** (already written, currently failing — Phase 3)

- `resolves base branch in a repository with no commits` — the reproduction test. ✗ → ✓
- `reports no branch when HEAD is detached` — locks the preserved behavior. ✓ already
- Update `FootprintBenchmarkTests.swift:75` for the removed `gitService:` argument.

Not covered by a test: `create` on a plain folder — it launches a real provider CLI, so it is
verified by running the app (see Validation).

## Files affected

| File | Change |
|---|---|
| `Sources/ZeroCore/Git/GitService.swift` | `resolveBaseBranch()` uses `branch --show-current`; guard simplified |
| `Sources/ZeroCore/Session/SessionRuntime.swift` | git optional in `create`; `gitService` property/param removed; `resume` no longer builds one |
| `Tests/ZeroCoreTests/Git/GitServiceTests.swift` | reproduction + detached-HEAD tests (done) |
| `Tests/ZeroCoreTests/Session/FootprintBenchmarkTests.swift` | drop the `gitService:` argument |

## Risks / side effects

- **`init.defaultBranch` naming.** In a repo with no commits the label is whatever `HEAD` points
  at (`main`/`master`) — a branch that does not exist yet. It is a label only; nothing branches
  from it.
- **A typo'd folder no longer errors early.** Losing `notARepository` for `.currentCheckout` means
  a wrong path is caught by the provider failing to start rather than by git. Accepted: requiring
  git as a path check was never the intent, and `.isolatedWorktree` still gets the hard check.
- **Removing the runtime's `gitService` is API-visible** (public `init`). In-repo callers are
  `create`, `resume`, `readOnly` and one test; nothing outside the package consumes it.
- **`isDirty()` and the branch label are the only in-place uses of git** — both non-blocking after
  this, so no other flow changes.

## Rollback
`git revert` the single fix commit. No migration, no persisted-schema change (`Session.branch`
stays a `String`), no worktree or file-system side effects to undo.

## Validation
`swift build` + `swift test` (full suite), then run the app against three folders: a plain folder
(no `.git`), a `git init` repo with no commits, and this repo — each starting a session in **Auto**
on "This checkout". Security scans (Snyk SAST/SCA, SonarQube) are **not available** in this
environment — see the tooling note in `ANALYSIS.md`; they will not be reported as clean.
