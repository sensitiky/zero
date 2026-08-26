# PRD — Toggleable file-tree panel with content preview

## Status
Approved (gate 1, 2026-08-25)

## Problem
Zero has no way to look at a session's files without leaving the app. The transcript shows what
the agent touched (via tool-call cells and diffs), but there is no way to browse the workspace
itself — see what else is there, open a file that wasn't part of any tool call, or get oriented in
an unfamiliar repository.

## Goals
- Browse the active session's workspace as a folder tree, expand/collapse folders, see files.
- Preview a file's contents without leaving Zero.
- Hide noise automatically: everything `.gitignore` excludes, and `.DS_Store` always, unconditionally.
- The panel costs nothing when you're not using it — hidden by default, one action to bring up.

## Non-goals
- **Editing.** This is a viewer. No save, no create/rename/delete/move from the tree. Zero already
  has an agent for making changes; this is for a human to look, not to edit around it.
- **Per-language colored icons.** File-type icons stay shape-only, per Zero's design system
  (`docs/DESIGN.md`: one accent hue, used in exactly two views, enforced by
  `Scripts/lint-design-tokens.sh`) — confirmed with the user at Gate 0. Still true after the
  reversal directly below: only the code preview's own text gets color, never the tree's icons.
- ~~Colorized syntax highlighting~~ **Reversed after Gate 3.** Originally a non-goal for the same
  monochrome reasoning as the icons — every other code surface in this app (`ToolCallCell`,
  `FileDiff`, `MarkdownText`'s fenced code) is plain monospace with no per-token color. The user
  asked for it back explicitly, by name ("vercel code theme"), after using the monochrome build.
  FR-6 now specifies real syntax highlighting for code files in the preview, via a small dedicated
  palette (`Theme.Syntax`) kept deliberately separate from `Theme.accent` — a code viewer's reader
  aid, not a UI status color, and outside what `lint-design-tokens.sh`'s accent-count check
  polices. What's still true: no new dependency (`SyntaxHighlighter` is a small hand-rolled
  tokenizer, not a bundled highlighting engine), and non-code files (markdown, plain text) still
  preview as plain monospace — highlighting only fires for recognized code extensions, not prose.
- **Full `.gitignore` semantics.** No nested per-directory `.gitignore` files, no `.git/info/exclude`,
  no global gitignore, no negation (`!pattern`). Root `.gitignore` only, common glob patterns
  (`*.ext`, `dir/`, `**/name`). See Open Questions/FR-4 for the exact supported subset. A repo whose
  ignore rules genuinely need nested files or negation will see files this panel doesn't hide that
  `git status` would — a known, stated gap, not a silent one.
- **A permanent third column.** Already decided against in this codebase —
  `UsageIndicator.swift`: *"Replaces a permanent inspector column. A second sidebar spends a fifth
  of the window on figures you glance at occasionally."* This panel is toggleable instead.
  Confirmed with the user at Gate 0.
- **Full-text search across files**, "reveal in Finder", or any write-adjacent affordance
  (drag-out, copy path). None of these were asked for; add them later if wanted.
- **Binary file preview** (images, PDFs). The tree lists them like any other file; selecting one
  shows a placeholder ("binary file, N bytes") rather than attempting to render or decode it.

## User stories
- As a user with a session open, I want to open a side panel and see the files in that session's
  workspace, so I can get oriented without leaving Zero.
- As a user browsing the tree, I don't want to see `node_modules`, build output, or anything else
  `.gitignore` already tells git to ignore — or `.DS_Store`, ever.
- As a user, I want to click a file and read its contents right there, without the panel eating
  space I'm not using it for.

## Functional requirements
1. A toggle (sidebar button + keyboard shortcut, mirroring how `ZeroCommands` already exposes
   other view toggles) shows/hides a trailing panel. Hidden by default; the shown/hidden state is
   not persisted across restarts — no FR asked for that, and `AppModel` growing a new piece of
   cross-launch UI state for a panel visibility flag is exactly the kind of thing to add when
   asked, not preemptively (see `006-persistent-projects-sessions`'s `LastSelection`, added because
   it was explicitly required).
2. The panel is empty/absent when no session is selected, and switches to that session's workspace
   the moment one is: `SessionSnapshot.worktreePath` for `.currentCheckout`, or the session's own
   worktree for `.isolatedWorktree` — never the project's repository root when they differ.
3. The tree walks the workspace root recursively (folders lazily expanded — a folder's children are
   only read when it's opened, not the whole tree up front), showing name, a folder/file-type icon,
   and expand/collapse state. Sorted: folders before files, alphabetical within each group —
   `NSString`'s localized comparison, matching how Finder and every other file browser already
   sorts.
4. Every entry excluded by the workspace root's `.gitignore` is hidden, using this supported
   subset: exact names, `*` glob wildcards, a trailing `/` meaning "directory only", and `**/`
   meaning "at any depth". Comments (`#`) and blank lines are skipped. Negation (`!pattern`),
   nested `.gitignore` files, and `.git/info/exclude` are not supported (see Non-goals). `.git/`
   itself is always excluded, gitignore or not — nobody browses their own git internals from a
   file tree.
5. `.DS_Store` is always hidden, unconditionally — independent of whatever the workspace's own
   `.gitignore` says, since a repository that never bothered to ignore it shouldn't leak it into
   the one place this app shows a clean tree.
6. Selecting a file shows its contents in the same panel (replacing the tree, with a way back — see
   UI/UX notes), as numbered monospace text via the same gutter idiom `FileDiff` already uses for
   a whole file. For a recognized code extension, the text is syntax-highlighted (keywords,
   strings, comments, numbers) using a small hand-rolled tokenizer and a dedicated palette
   (`Theme.Syntax`) — not per-language grammars, a generic-but-reasonable scan good enough for the
   languages this app's own users read (see Non-goals for what changed here after Gate 3). A file
   whose extension isn't recognized as code (markdown, plain text, unknown) previews as plain
   monospace, unhighlighted. A file that fails to decode as UTF-8 text shows a "binary file"
   placeholder instead of garbled bytes or a crash.
7. A file's content is read fresh each time it's selected — no caching, no live file-watching. If
   the agent (or you, outside Zero) changes a file while its preview is open, the preview goes
   stale until you reselect it. Explicit scope line: FR asks for a viewer, not a live editor's
   reflection of disk state.
8. Reading is bounded to the workspace root the same way `GitService.validatePathInsideRepository`
   already bounds worktree operations — a symlink inside the tree cannot be used to read a file
   outside the workspace. Shared, not reimplemented differently for this feature (see Data model /
   architecture notes).
9. A file above **1 MB** shows a "too large to preview" placeholder instead of attempting to
   render it (resolved in Open Questions).

## Non-functional requirements
- Directory listing and gitignore matching happen off the main actor — the same NFR this app holds
  everywhere else (`ZeroCore`'s transport/decoding layer, `SessionRuntime`'s persistence hop) for
  the same reason: a large `node_modules`-adjacent tree walk on the main actor is exactly the kind
  of stall `004-composer-input-lag` already showed this app is unforgiving about.
- No new external dependency. Gitignore matching (the stated subset) and directory walking are both
  a few dozen lines of `FileManager`/`String` — not something `Package.swift` needs a library for.
- Icons: SF Symbols, matching every other icon already in this app's chrome (see `SidebarHeader`,
  `CircleButton`, `StateDot`) — not a bundled icon font or image set.

## Data model changes
None. This is derived, read-only state — a tree walk and a file read, not something `Store`
persists. No new SwiftData model, no new `Session` field.

One shared architecture note: `GitService.validatePathInsideRepository`/`resolvePathFully` (path
containment, symlink-safe) is `private` and scoped to git worktree operations today. This feature
needs the same guarantee for reading file content that never touches git. The plan should extract
that into something both can call rather than duplicating a security-sensitive path check with
subtly different behavior in two places.

## UI/UX notes
- Toggle: ⌘B, via `ZeroCommands`' `CommandGroup(after: .sidebar)` (resolved in Open Questions) —
  exact button placement in the window chrome (e.g. trailing toolbar item) decided at the plan
  stage against the current layout; the shortcut and its menu entry are settled regardless of
  where the button sits.
- Tree and file preview share one panel, not two: selecting a file replaces the tree view with the
  preview; a back control returns to the tree — breadcrumb vs. a plain back button decided at the
  plan stage, keeping the panel's width from having to hold both a tree and a wide code view side
  by side.
- Empty states: no session selected → panel shows nothing to browse; workspace has no files beyond
  what's ignored → "Nothing to show" (matches the tone of existing empty states like
  `EmptyStatePane`).
- Icon-per-type mapping: resolved in Open Questions.

## Open questions
Resolved at Gate 1:
- **Keyboard shortcut: ⌘B**, the standard "toggle sidebar/tree" binding this class of panel
  already carries in every comparable app. Menu command lives in `ZeroCommands`'
  `CommandGroup(after: .sidebar)`, next to the existing session-navigation commands — same
  reasoning FR-27 already established there: a menu command is what makes a shortcut discoverable
  instead of folklore.
- **File-size ceiling: 1 MB.** In line with what other tools draw the same line at (GitHub's blob
  view stops rendering around the same order of magnitude), and conservative given this app's own
  history with large-text rendering cost (`004-composer-input-lag`).
- **Icon set** (SF Symbols, shape only): folder / folder (expanded); `.swift` → `swift` (Apple
  ships this symbol); source code (`.js`/`.jsx`/`.ts`/`.tsx`/`.py`/`.rb`/`.go`/`.rs`/`.c`/`.h`/
  `.cpp`/`.hpp`/`.java`/`.kt`/`.sh`) → `chevron.left.forwardslash.chevron.right`; structured data
  (`.json`/`.yml`/`.yaml`/`.xml`/`.toml`) → `curlybraces`; markup (`.md`/`.txt`/`.html`) →
  `doc.text`; images (`.png`/`.jpg`/`.jpeg`/`.gif`/`.svg`/`.webp`) → `photo`; `.pdf` →
  `doc.richtext`; lockfiles/manifests (`Package.swift`, `package.json`, `*.lock`) →
  `doc.badge.gearshape`; anything else → `doc` (the stated fallback, never blank).

## Functional requirements (added after Gate 3 — git diff indicators)
New scope, not in the original approval: a file or folder with uncommitted changes shows a diff
color in the tree, and a changed file's preview shows a real diff against `HEAD`, not just its
plain content.

10. Every file with uncommitted changes (`git status`: modified, staged, or untracked) is colored
    in the tree — green for new/untracked, amber for modified — reusing `Theme.Syntax`'s palette
    rather than a third one. A folder containing any such file is colored the same way, rolled up
    from its descendants (modified wins over added when a folder has both).
11. A deleted-but-tracked file has no indicator — the tree lists what exists on disk, and a
    filesystem walk cannot show a row for a file that isn't there. Stated limitation, not a bug.
12. Selecting a **changed** text file shows a real diff against `HEAD` (new/untracked files diff
    against nothing — the whole file reads as added) instead of the plain preview, reusing
    `DiffView`/`FileDiff` exactly as tool-call edits already render. An **unchanged** file keeps
    the existing plain/syntax-highlighted preview. **Revised — now combined** (originally scoped
    as separate; see FR-15 below): a changed file's diff is syntax-highlighted too, via the same
    tokenizer, layered on top of (not instead of) the diff's own added/removed tint.
13. Workspaces that aren't git repositories (or where the `git status` read fails) show no
    indicators at all, the same degrade-gracefully behavior `SessionRuntime.create`'s own
    `try? GitService(...)` already uses elsewhere in this app — never an error state.
14. `.gitignore`'s own subset limitations (Non-goals) apply equally to status parsing: a rename is
    recorded under its new path only, not represented as a rename.

## Functional requirements (added after Gate 3 — live watching + combined highlighting)
15. While the panel is showing a session's tree, a change to any file under that workspace — from
    the agent, an external editor, or `git` run by hand — updates the listing, the diff indicators,
    and (for a currently-open changed file's diff view) the diff itself, without the user closing
    and reopening the panel. A currently-expanded folder's contents refresh too. Watching starts
    when the panel appears and stops when it's hidden — no background cost while closed.
16. A file/folder's diff-color change is animated (a quiet cross-fade, not a hard cut) so a live
    update reads as "this changed" rather than a glitch; row insertion/removal from a live change
    is not animated this round (deliberately — see PLAN.md's addendum for why).
17. A changed file's in-file diff (FR-12) is syntax-highlighted using the same tokenizer FR-6
    already established, layered on top of the diff's own monochrome added/removed tint rather
    than replacing it.

## Conflicts / dependencies
- Reverses the literal request's "colorful icons + syntax highlighting" in favor of Zero's existing
  monochrome design law — confirmed with the user at Gate 0, not assumed silently.
- Reverses the literal request's "always-visible sidebar" in favor of the toggleable panel the
  `001-agent-chat-core`/`UsageIndicator` precedent already established — confirmed with the user at
  Gate 0.
- Depends on `SessionRuntime.Workspace` (`001-agent-chat-core`) to resolve the correct root, and on
  extracting `GitService`'s path-containment check (also `001-agent-chat-core`) into a shared form.
