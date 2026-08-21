# Branch flow (incu)

- Uniform branch flow, always via PR, never a direct merge: `feat/{slug}` or `fix/{slug}` → `develop` → `main`.
- All work happens on an isolated branch (or worktree) chosen before any file is written.
- Never `git push --force` to `main`; never skip git hooks (`--no-verify`).
