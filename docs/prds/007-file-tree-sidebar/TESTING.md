# Testing Guide — Toggleable file-tree panel with content preview

## Status
Ready for user testing.

## New: live watching + combined diff/syntax highlighting
- **Live updates.** With the tree open, change a file outside Zero (edit it, save it, or run
  `git add`/`git commit`/`git checkout` in Terminal). Expect the tree's colors and the listing to
  update within roughly a second, without closing/reopening the panel — including inside an
  already-expanded folder.
- **Quiet color transition.** Watch a file's name while you make it dirty (e.g. save an edit in
  another editor while looking at the tree). Expect a brief, smooth cross-fade to amber, not an
  instant snap.
- **Diff + syntax highlighting combined.** Open a **changed** code file's preview. Expect both at
  once: diff line markers/background tint AND colored keywords/strings/comments/numbers within
  each line, not just plain diffed text.

## New: git diff indicators
Not a fix — new scope, added on request. Modify or add a file in the workspace you're browsing
(outside Zero is fine — edit it in another editor, or `touch newfile.txt` in Terminal), then look
at the tree without needing to close/reopen it (it re-reads git status each time the panel loads
for that session; reselect the session or close/reopen the panel to force a refresh if you edited
the file while the tree was already open).

## Changes after the second round of testing
- **State survives closing and reopening the panel.** Expanded folders and the file you had open
  stay as you left them — switching sessions still resets the tree (correctly, it's a different
  workspace), but toggling the panel itself no longer does.
- **Tighter, VS-Code-like indentation.** Nested folders no longer eat most of the panel width in
  blank leading space.
- **Resizable.** Drag the divider between the conversation and the panel (200–520pt range, cursor
  changes to a resize arrow on hover).

## Changes after the first round of testing
Two corrections from your feedback:
- **⌘B now toggles the session/project sidebar; ⌘F toggles the file tree.** (Originally both were
  going to share ⌘B.)
- **Real syntax highlighting for the code preview** — keywords, strings, comments, and numbers are
  now colored (a small dedicated palette, `Theme.Syntax`, kept separate from the app's one accent
  color). Applies to recognized code extensions; markdown/plain text still preview unhighlighted.

## What was already verified automatically
- `swift build` — clean.
- `swift test` — **438 tests passing** (437 after the git-diff-indicators round, +1 this round:
  `WorkspaceWatcherTests`, a real FSEvents integration test — create a temp directory, watch it,
  touch a file, confirm the callback fires within a timeout) (391 before this feature, 417 after the first
  implementation, 425 after the syntax-highlighting/keybinding round). New this round:
  `GitFileStatusTests` (12, in `Tests/ZeroCoreTests/Git/`) covering `workingTreeStatus()`,
  `headContent(ofRelativePath:)`, and `GitFileStatus.rollup(_:)`. Total new coverage across the
  whole feature: `PathContainmentTests` (5), `GitignoreMatcherTests` (8), `WorkspaceTreeTests` (5),
  `WorkspaceFileReaderTests` (5), `FileIconTests` (3), `SyntaxHighlighterTests` (8),
  `GitFileStatusTests` (12) — 46 total, plus the existing `GitServiceTests` (21) confirmed
  unchanged after `PathContainment` was extracted out of `GitService`. The syntax highlighter's own
  tests caught two real bugs before they shipped (a case-name collision with `Optional.none`, and
  a number-detection guard that silently swallowed digits) — see `PLAN.md`'s addenda.
- `Scripts/lint-design-tokens.sh` — clean. No new accent-color or hue usage anywhere in this
  feature; icons and preview text are shape/weight only.
- `Scripts/make-app.sh` — builds `build/Zero.app` clean.
- Smoke-tested against the real built app: launched, quit, relaunched — clean each time, no crash,
  no new entry in `~/Library/Logs/DiagnosticReports/`.

What's below needs a person clicking through the real app — this is a SwiftUI view feature with no
test harness for the `Zero` target (same convention `006-persistent-projects-sessions` and
`004-composer-input-lag` already followed), so the tree, the preview, and the toggle itself all
need eyes on them.

## How to test
1. Build and open the app:
   ```bash
   cd Scripts && ./make-app.sh && cd ..
   open build/Zero.app
   ```
2. Open (or restore) a session in a real repository — ideally one with a `.gitignore` that
   excludes something real (`node_modules/`, `build/`, `.DS_Store` if it happens to have one) so
   there's something to confirm is hidden.

## Scenarios

### 1. Toggle
1. With a session open, press **⌘F** (or use the menu — check the Window/View menu for "Show File
   Tree"). Expect: the panel appears to the right of the conversation, no layout jump elsewhere.
2. Press ⌘F again. Expect: it hides, and the conversation pane reclaims the space instantly.
3. With **no session selected**, check the "Show File Tree" menu command is disabled (grayed out)
   — the shortcut shouldn't do anything either.
4. Press **⌘B**. Expect: the session/project sidebar on the left hides; press it again to bring it
   back. This should work regardless of whether a session is selected.

### 2. Browsing
1. Expand a few folders. Expect: folders sort before files, both alphabetical; icons are
   monochrome shapes (no color) — a Swift file shows the Swift logo glyph, a `.md`/`.txt` shows a
   document glyph, an image shows a photo glyph, etc.
2. Confirm anything your repo's `.gitignore` excludes (`node_modules`, `build`, `dist`, whatever
   applies) **never appears** in the tree, at any depth.
3. Confirm `.DS_Store` never appears, even if you know this particular repo's `.gitignore` doesn't
   mention it (create one with `touch .DS_Store` in the workspace if you want to force the case).
4. Confirm `.git` never appears.

### 3. Preview
1. Click a code file (`.swift`, `.js`/`.ts`, `.py`, `.json`, etc.). Expect: numbered monospace
   lines with **keywords, strings, comments, and numbers colored** — not plain black/white text.
   Text stays selectable, a back arrow at top returns to the tree.
2. Click a markdown or plain-text file. Expect: numbered monospace lines, **unhighlighted** — no
   coloring, matching the original plain preview.
3. Click an image or other binary file. Expect: a "Binary file, N bytes" placeholder — not garbled
   text, not a crash.
4. If you have (or can make) a file over 1 MB, click it. Expect: "Too large to preview" with its
   size shown, not an attempt to render it.
5. In a Swift file, look for something like `#available` or any `#`-prefixed directive if present.
   Expect: it does **not** get colored as a comment — only `//` starts a comment in
   slash-comment languages.

### 4. Workspace root follows the session
1. Open a `.currentCheckout` session — the tree root should be the project's own folder.
2. Open (or start) an `.isolatedWorktree` session in the same project — the tree root should be
   that session's own worktree folder, which has a different (though related) file set, not the
   project's root.

### 5. Restored session (if you have one from `006-persistent-projects-sessions`)
1. Quit and reopen Zero, select a restored session, toggle the tree.
2. Expect it resolves and browses normally — this doesn't depend on anything about how the session
   was restored, just its `worktreePath`.

### 6. State survives closing the panel
1. Expand a couple of nested folders (a folder inside a folder), open a file's preview.
2. Press ⌘F to close the panel, then ⌘F again to reopen it.
3. Expect: the same folders are still expanded, and you're looking at the same file preview you
   had open — not back at the collapsed root tree.
4. Now switch to a **different session** and open the tree. Expect: it shows *that* session's
   tree, fully collapsed — the previous session's expanded state doesn't leak across sessions.

### 7. Indentation and resize
1. Expand a folder nested two or three levels deep. Expect: each level's indent is small and
   consistent (~14pt) — not a growing wall of blank space before the icon.
2. Hover the divider between the conversation and the tree. Expect: the cursor changes to a
   left-right resize arrow.
3. Drag it. Expect: the panel resizes smoothly between roughly 200 and 520pt; the conversation
   pane reclaims/gives up space accordingly.

### 8. Diff indicators in the tree
1. In a git-tracked project, modify a tracked file and add a brand-new untracked file, ideally in
   a nested folder. Open (or reopen) the file tree.
2. Expect: the modified file's name is **amber**, the new file's name is **green** — not the
   ordinary text color.
3. Expect: every ancestor folder of each — all the way up — is colored the same way. If a folder
   contains both a modified and a new file, expect it to read as modified (amber), not new.
4. A file with no changes, and folders with no changed descendants, stay the ordinary color.
5. In a folder that isn't a git repository at all (or a plain non-repo folder you point a
   `.currentCheckout` session at), confirm the tree still works normally with no indicators and no
   error.

### 9. Diff inside the file preview
1. Click the **modified** file from scenario 8. Expect: instead of the plain preview, you see a
   real diff against the last commit — added/removed lines marked, tinted backgrounds, **and**
   colored keywords/strings/comments/numbers within each line (both at once, not one or the
   other).
2. Click the **new/untracked** file. Expect: it shows as a whole new file (every line reads as
   added), also syntax-highlighted — there's nothing to diff it against, but it's still code.
3. Click an **unchanged** file. Expect: the ordinary plain/syntax-highlighted preview, unchanged
   from before this round — no diff markers.

## Known limitations (by design — see the PRD)
- No editing — this is a viewer.
- `.gitignore` support covers exact names, `*` globs, `dir/`, and `**/`; no negation (`!pattern`),
  no nested per-directory `.gitignore` files, no `.git/info/exclude`, no global gitignore. A repo
  that leans on any of those will show a file this panel doesn't hide that `git status` would.
- An open file's own preview does not live-update if the file changes while you're reading it —
  only the tree (listing, diff colors, an *unopened* changed file's would-be diff) refreshes live.
  Reselect the file to see new content.
- No search, no "reveal in Finder", no drag-out — none of these were asked for.
- New/removed rows from a live change aren't animated (deliberate — see `PLAN.md`'s addendum);
  only an existing row's status color cross-fades.
- No indicator for a deleted-but-tracked file — the tree walks the filesystem, and a deleted file
  isn't on it to have a row.
- A renamed file shows only under its new path/name — the rename itself isn't represented.
- Syntax highlighting is one generic tokenizer (keyword/string/comment/number) shared across
  languages, not per-language grammars — it won't catch every language-specific nuance (e.g. Swift
  raw strings, Python f-strings' embedded expressions). Block comments (`/* */`) spanning multiple
  lines aren't recognized, only line comments — a line-at-a-time scanner has no memory of "still
  inside a comment from two lines up."

## Security scans — not run
Per `.claude/rules/security.md`: Snyk SAST, Snyk SCA, and SonarQube are all unavailable in this
environment (no MCP tools, no `run-sonnar.sh` in the repo) — same as the previous two branches.
**Waived by the user 2026-08-25** — recorded here and in `.ways/state.json`, not reported as
clean.

## Reporting back
For each scenario: pass/fail, and if it fails, what you saw instead of what's listed under
"Expect".
