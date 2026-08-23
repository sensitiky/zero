# Bug — A repository with no commits (unborn `HEAD`) cannot start a session

## Status
Fixed

## Description
Starting a chat in a folder where `git init` was run but nothing has been committed fails
immediately with a git error instead of starting the agent. The same folder *before* `git init`
also fails, with a different git error — a session in the current checkout should not require git
at all.

## Steps to reproduce
1. `mkdir /tmp/fresh && cd /tmp/fresh && git init` (no commits, no branches).
2. Open Zero, add that folder as the project, "Choose Repository".
3. Pick provider Claude Code, permission mode **Auto**, workspace **This checkout**.
4. Type a message and send.

## Expected behavior
The session starts and the agent runs in that folder. Git is metadata here: `.currentCheckout`
never creates a branch or a worktree, so a missing commit — or a missing repository — should not
block the session.

## Actual behavior
No session is created. The compose error reads:

```
Git: commandFailed(command: "rev-parse --abbrev-ref HEAD", exitCode: 128, stderr: "fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.\nUse '--' to separate paths from revisions, like this:\n'git <command> [<revision>...] -- [<file>...]'\n")
```

A folder with **no** `.git` at all fails the same way earlier, with
`Git: notARepository(path: …)`.

## Context
- Environment: local (macOS), Zero from `develop` (`e11a069`)
- Affected commit / version: present since `91b3499` (`feat(001-agent-chat-core)`) — `GitService`
  has always used `rev-parse --abbrev-ref HEAD`
- Affected users or records: anyone starting a session in a brand-new repo or in a plain
  (non-git) folder. Permission mode is irrelevant — Auto is just how it was hit.
- Severity: High — the app is unusable for those folders, and it is the first thing a new user does.

## Logs / stack trace
Surfaced as `SessionRuntime.CreationError.gitError`, rendered by `SessionCoordinator.lastError`.
No crash.
