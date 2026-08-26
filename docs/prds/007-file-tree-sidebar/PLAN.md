# Implementation Plan — Toggleable file-tree panel with content preview

## Branch / worktree
Branch name: `feat/007-file-tree-sidebar`
Isolation mode: current checkout branch

## Design decisions (settled here, not re-litigated per task)

- **Panel is a plain `HStack`, not a third `NavigationSplitView` column.** A 3-column
  `NavigationSplitView` would move `RootView`'s existing `detail:` (the conversation) into the
  `content:` slot and restructure column semantics that work today. An `HStack` inside `RootView`'s
  `detail:` closure — `ConversationPane` then `Divider` then the panel when shown — is the smaller,
  lower-risk change and matches "toggleable, costs nothing hidden": zero layout cost when
  `model.showsFileTree` is false.
- **Fixed width, not user-resizable.** `NavigationSplitView` columns get draggable resize for free;
  a plain `HStack` doesn't. The PRD never asked for resizing. Fixed at 280pt — the sidebar's own
  `ideal` width token — rather than building a drag handle nobody requested.
- **Not `DiffView`/`FileDiff`.** `FileDiff` models hunks, gaps, and dual old/new columns — a diff's
  shape, not a file's. Forcing a plain preview through it would be more code than a dedicated
  single-column numbered-line view, even though both end up using the same `Theme.code()` +
  gutter-number idiom. Shared idiom, not shared type.
- **`PathContainment` extracted from `GitService`.** `resolvePathFully`/`validatePathInsideRepository`
  are pure `FileManager`/`NSString` path math with no git in them — `private` today only because
  nothing else needed them yet. Extracting keeps the file reader's escape-prevention identical to
  the worktree code's, rather than a second implementation that could drift from the first.
- **Lazy children live in the UI layer, not `ZeroCore`.** `WorkspaceTree.children(of:)` returns one
  directory level and is called again when a folder expands — a pure, stateless, per-call read.
  The cache of "which folders are already expanded, what did we read for them" is `@State` in the
  view, not a stateful cache inside `ZeroCore`. Matches how `ZeroCore` stays pure/testable
  elsewhere (`ComposerMetrics`, `FileDiff`) and UI-layer state stays in `Zero`.

## Phases

### Phase A — Core domain (`ZeroCore`, pure, tested without a filesystem where possible)

- [ ] **A1** `Sources/ZeroCore/FileSystem/PathContainment.swift` (new module folder, matching the
      one-concern-per-folder convention `Diff/`/`Git/`/`Session/` already use): extract
      `resolvePathFully`/`validatePathInsideRepository` out of `GitService` into a standalone type
      — symlink-safe, cycle-safe, same behavior. `GitService` calls it instead of its private copy;
      its own copy is deleted. Existing `GitServiceTests` (`pathOutsideRepositoryRejected`,
      `symlinkEscapeRejected`) must keep passing unchanged — they're the regression test for this
      extraction.
- [ ] **A2** `Sources/ZeroCore/FileSystem/GitignoreMatcher.swift`: parses `.gitignore` text into
      the stated subset (exact names, `*` glob, trailing `/` = directory-only, `**/` = any depth;
      `#` comments and blank lines skipped; no negation, no nested files — PRD Non-goals). Pure:
      `init(patterns: String)`, `func matches(relativePath: String, isDirectory: Bool) -> Bool`. No
      filesystem access — testable against string fixtures directly.
- [ ] **A3** `Sources/ZeroCore/FileSystem/WorkspaceTree.swift`: `WorkspaceEntry` (`id`/`url`/`name`/
      `isDirectory`) and `static func children(of directory: URL, root: URL, ignoring: GitignoreMatcher) throws -> [WorkspaceEntry]`
      — one level, folders before files, localized alphabetical within each group
      (`localizedStandardCompare`). Always excludes `.git` and `.DS_Store` regardless of what the
      matcher says (PRD FR-4/FR-5); everything else goes through `PathContainment` (a listed
      entry's resolved path must stay under `root`) and the matcher.
- [ ] **A4** `Sources/ZeroCore/FileSystem/WorkspaceFileReader.swift`:
      `enum Content { case text(String), binary(bytes: Int), tooLarge(bytes: Int) }`,
      `static func read(_ file: URL, root: URL) throws -> Content`. Bounded by `PathContainment`
      first; a file over **1 MB** is `.tooLarge` without reading it; otherwise reads bytes and
      attempts UTF-8 decode — failure is `.binary`, not a crash or mojibake.

### Phase B — UI

- [ ] **B1** `Sources/Zero/AppModel.swift`: `var showsFileTree = false` — transient, not persisted
      (PRD Non-goals: no cross-launch panel-visibility state was asked for).
- [ ] **B2** `Sources/Zero/ZeroCommands.swift`: `CommandGroup(after: .sidebar)` gains "Toggle File
      Tree", `⌘B`, toggling `model.showsFileTree`, disabled when `model.selectedSession == nil`
      (mirrors the existing "New Session" disabled-when-empty pattern in the same file).
- [ ] **B3** `Sources/Zero/FileTree/FileIcon.swift`: pure `extension → SF Symbol` mapping per the
      PRD's resolved icon set, folder open/closed handled separately from the extension table,
      unmapped extensions fall back to `"doc"`.
- [ ] **B4** `Sources/Zero/FileTree/FileTreeRow.swift` + the tree view: recursive disclosure rows.
      Expanding a folder calls `WorkspaceTree.children(of:)` off the main actor (`Task`), caches
      the result in `@State` keyed by URL so re-collapsing/re-expanding doesn't re-read the
      directory; a folder with a pending read shows no spurious flash (children populate before
      the disclosure opens, or the row shows nothing new until they do — no spinner UI, this is
      expected to be fast for the directory sizes this app deals with).
- [ ] **B5** `Sources/Zero/FileTree/FilePreviewView.swift`: numbered monospace lines via
      `Theme.code()` + the gutter idiom `ToolCallCell`'s diff rows already establish (line number,
      `Theme.secondary`, then the line, `.textSelection(.enabled)`) — no diff markers, no tint, no
      hunk gaps: every line, in order. `.binary`/`.tooLarge` show a centered placeholder message
      instead.
- [ ] **B6** `Sources/Zero/FileTree/FileTreePanel.swift`: root of the panel — the tree by default;
      selecting a file swaps to `FilePreviewView` with a back button returning to the tree (state:
      local `@State` selected-file, not `AppModel` — this is view-local navigation, not something
      any other view needs to observe). Empty states per the PRD (no session → nothing to browse;
      workspace has nothing to show → "Nothing to show", styled like `EmptyStatePane`).
- [ ] **B7** `Sources/Zero/RootView.swift`: `detail:` closure becomes
      `HStack(spacing: 0) { ConversationPane(...); if model.showsFileTree, model.selectedSession != nil { Divider(); FileTreePanel(...).frame(width: 280) } }`
      — resolves the workspace root per session per the PRD (FR-2): `session.worktreePath`, which
      already reflects `.currentCheckout` vs. `.isolatedWorktree` correctly (see
      `SessionCoordinator`'s existing `worktreePath` plumbing from `006-persistent-projects-sessions`).

## Test plan

- **Unit** (`Tests/ZeroCoreTests/FileSystem/`, new directory matching `Persistence/`/`Git/`'s
  per-module test layout):
  - `PathContainmentTests`: a path under root passes; a path outside root, and a symlink resolving
    outside root, both throw. (New tests against the extracted type directly, in addition to the
    existing `GitServiceTests` that exercise it indirectly through `GitService`.)
  - `GitignoreMatcherTests`: exact name, `*.ext`, `dir/` (directory-only, doesn't match a file of
    the same name), `**/name` (any depth), comments and blank lines ignored, no match for a
    pattern that would need negation to express (documents the stated gap rather than silently
    half-supporting it).
  - `WorkspaceTreeTests`: folders sort before files; alphabetical within each group; a gitignored
    entry is excluded; `.git` is excluded even with an empty/absent `.gitignore`; `.DS_Store` is
    excluded even when the fixture's `.gitignore` doesn't mention it; a symlink escaping `root` is
    excluded rather than thrown (a listing skips what it can't safely show, it doesn't blow up the
    whole directory).
  - `WorkspaceFileReaderTests`: a small UTF-8 file round-trips as `.text`; invalid UTF-8 bytes come
    back `.binary`; a file just over 1 MB comes back `.tooLarge` without its bytes ever being read
    (assert on a large *sparse/placeholder* fixture, not by actually allocating 1 MB+ of test data
    if a smaller equivalent proves the boundary — decide the exact fixture size at implementation
    time); a path outside `root` throws.
  - `FileIconTests`: representative sample across the mapping table (one from each category) plus
    the unmapped-extension fallback.
- **Manual** (`Zero` app target has no test harness — same convention `006-persistent-projects-sessions`
  and `004-composer-input-lag` already followed): full checklist in `TESTING.md` at Gate 3 —
  toggle via button and ⌘B, browse nested folders, confirm a gitignored folder (e.g. a repo with
  `node_modules` or `build/` ignored) never appears, confirm `.DS_Store` never appears even in a
  repo that never gitignored it, preview a text file, preview a binary file (placeholder, not
  garbage), preview a >1 MB file (placeholder), switch between an `.currentCheckout` and an
  `.isolatedWorktree` session and confirm the tree root changes accordingly, panel state with no
  session selected.

## Rollback notes
Additive: one new `ZeroCore` module folder, one new `Zero` UI module folder, three small edits to
existing files (`AppModel`, `ZeroCommands`, `RootView`) that are no-ops when `showsFileTree` is
false, and a mechanical extraction inside `GitService` covered by its own existing tests. Reverting
the branch returns to today's behavior exactly; no data, no schema, nothing persisted.

## Addendum — post-Gate-3 (syntax highlighting, sidebar keybinding)

Two changes made after user testing on the original implementation, both by explicit request:

- **⌘B now toggles the session/project sidebar** (`AppModel.sidebarVisibility`, bound to
  `NavigationSplitView(columnVisibility:)`) and **⌘F toggles the file tree** — the PRD's Gate-1
  resolution had put the file tree on ⌘B; the user corrected this after seeing it in the running
  app. The session sidebar had no explicit toggle command before this at all.
- **`SyntaxHighlighter`** (`Sources/ZeroCore/FileSystem/SyntaxHighlighter.swift`): a small,
  dependency-free per-line tokenizer (keyword / string / comment / number / plain), gated to
  recognized code extensions only (markdown/text still preview as plain monospace). Rendered via a
  new `Theme.Syntax` palette, deliberately kept separate from `Theme.accent`. Reverses the PRD's
  original "monochrome preview" non-goal — see the PRD's Non-goals section for the reasoning and
  what's still true (no new dependency, no per-language icon colors, prose still unhighlighted).
  Two real bugs caught by its own unit tests before this shipped: a `CommentStyle.none` case
  colliding with `Optional.none` (renamed to `.noComments`), and a number-detection guard that
  silently swallowed digits appearing after any non-letter character on the line.

## Addendum 2 — post-second-round feedback (state loss, indentation, resize)

Three more corrections, all from using the built panel:

- **Closing and reopening the panel lost your place** (expanded folders, the file you had open).
  Root cause: `FileTreePanel`/`FileTreeRow` held that state in local `@State`, and SwiftUI tears
  down a view's `@State` the moment it's removed from the hierarchy — which is exactly what
  `if model.showsFileTree { FileTreePanel(...) }` does on every toggle. Fixed by lifting all of it
  (`FileTreeState`: expanded folders, cached children per folder, the selected file) into a plain
  `@State` owned by `RootView`, which is never removed. `FileTreePanel`/`FileTreeRow` now hold no
  state of their own — they read and write `FileTreeState` by reference. `resetIfRootChanged`
  clears it when the session actually changes; reopening the *same* session's tree is a no-op, not
  a fresh read.
- **A lot of blank leading space on nested folders.** `DisclosureGroup`'s native macOS indent is
  generous — built for a settings form, not a dense file list — and a few levels of real nesting
  read as mostly whitespace. Replaced with an explicit `depth * 14pt` indent and a small manual
  chevron button, no `DisclosureGroup` at all — the tight, VS-Code-like spacing the original ask
  actually described.
- **Resizable**, reversing this plan's original "fixed width" design decision. A plain `HStack`
  gets no free column-resize the way `NavigationSplitView` columns do (the reason that wasn't used
  for this panel in the first place — see the top-level design decisions above); a proper 3-column
  `NavigationSplitView` was reconsidered here too, but its `columnVisibility` has no case for
  hiding only the trailing column while the others stay — it can't express "toggleable file tree,
  everything else unaffected" at all, so it was ruled out again. `ResizableDivider` (new) is a
  manual drag handle instead: a `DragGesture` adjusting `RootView`'s `fileTreeWidth` `@State`,
  clamped to `200...520`, with the resize cursor on hover. Not persisted across restarts — not
  asked for, and `fileTreeState`/`fileTreeWidth` living in `RootView` rather than `AppModel` was
  already the deliberate choice for UI-local state nothing else needs to reach.

## Addendum 3 — git diff indicators (new capability, not a fix)

New request, not a correction: per-file/folder diff indicators in the tree, and a real diff inside
the file preview for a changed file. Genuinely new scope beyond every FR the PRD originally listed
— recorded here rather than folded silently into an existing FR, same as this document's other
addenda.

- **`GitService` gains two methods**: `workingTreeStatus() -> [String: GitFileStatus]` (parses
  `git status --porcelain=v1 -uall`; a new `ZeroCore/Git/GitFileStatus.swift` defines the two
  cases that matter for a tree row — `.modified`, `.added` — deleted files have no row since
  nothing on disk exists to show one for) and `headContent(ofRelativePath:) -> String?` (`git show
  HEAD:path`, `nil` for a file with no version there). Both best-effort at the call site — a
  workspace that isn't a git repository just shows no indicators, the same degrade-gracefully
  pattern `SessionRuntime.create`'s own `try? GitService(...)` already uses.
- **`GitFileStatus.rollup(_:)`** (pure, tested) walks a file-status map up to every ancestor
  folder — a folder is `.modified` if any descendant is, else `.added` if any descendant is,
  matching what "this folder has a change in it" should mean.
- **Tree row coloring** reuses `Theme.Syntax`'s green/amber (`.added`/`.modified`, new thin
  aliases on that enum) rather than a third palette — see `Theme.Syntax`'s updated doc comment.
  Computed per row from `FileTreeState.gitStatus`/`.gitStatusByFolder`, populated once in
  `FileTreePanel.load()` alongside the directory listing and gitignore matcher.
- **In-file diff reuses `DiffView`/`FileDiff` outright** — the exact component `ToolCallCell`
  already renders a tool call's edit through — via a synthetic `FileEdit(path:, oldText:, newText:)`
  built from `HEAD`'s content (or `nil` for a new/untracked file, same as a `Write` tool call with
  no previous version) and the file as it is now. No new diff-rendering code at all. An unchanged
  file keeps the existing plain/syntax-highlighted view; the two aren't combined (a changed file's
  diff view is plain, not also syntax-highlighted) — a stated limitation, not an oversight.
  **Superseded by Addendum 4 below** — it now is.

## Addendum 4 — live watching + combined diff/syntax highlighting

Two more additions, both by explicit request. `design-taste-frontend` was invoked for the second
one, per the request — its actual content (Tailwind, Motion/framer-motion, GSAP, React) doesn't
apply to a native SwiftUI app, and it says so itself ("out of scope: native mobile, use Apple HIG
directly"). What transferred: motion has to be motivated (a real state change, not decoration),
respect reduced-motion, and don't stack two competing foreground treatments. Applied through
Zero's own existing native system (`Theme.Motion`, `.zeroAnimation`), not borrowed web patterns.

- **`WorkspaceWatcher`** (new, `Sources/ZeroCore/FileSystem/WorkspaceWatcher.swift`): wraps
  FSEvents (`CoreServices`) — the only macOS mechanism that watches a directory subtree
  recursively without a descriptor per path. Not `kFSEventStreamCreateFlagIgnoreSelf`: that flag
  filters by which process caused a change, and the point here is to catch changes from *any*
  source (agent subprocess, external editor, `git checkout` by hand) — its own integration test
  caught this the first time round (the test itself writes from the watcher's own process, which
  `.ignoreSelf` silently swallowed). Also resolves symlinks before watching — `/var/folders`-style
  temp-dir paths are themselves a symlink, and FSEvents watches the real path underneath.
- **`FileTreePanel`** starts a watcher on `root` while the panel is on screen (stopped in
  `.onDisappear` — background work that should not run while hidden, same reasoning as everything
  else "toggleable" in this PRD), debounced (0.5s) via FSEvents' own coalescing latency. A change
  re-reads the listing, git status, and every currently-*expanded* folder's children — but never
  touches `expandedFolders` or `selectedFile`: a background refresh doesn't get to reset the
  user's place, same rule `resetIfRootChanged` already draws for a session switch versus a reopen.
- **The status-color transition is motion, keyed to the row, not the write.** A plain
  `withAnimation` at the state-mutation site was the first draft and it's wrong for this codebase:
  `Scripts/lint-design-tokens.sh` bans `withAnimation(`/`.animation(` outside `.zeroAnimation`
  specifically so reduced-motion is honoured per-view, not assumed. Fixed by moving the animation
  onto `FileTreeRow`'s own `Text`, keyed to its derived `gitStatus` via
  `.zeroAnimation(Theme.Motion.value, value: gitStatus)` — the same token `UsageIndicator`'s
  figures already move under. Row insertion/removal (a brand-new file appearing) is deliberately
  **not** animated this round — replicating `ToolCallCell`'s manual reveal-flag choreography for a
  background-refresh event felt like decoration without a clear "what does this communicate,"
  which is exactly what taste-checking is for.
- **`SyntaxHighlightedText`** (new, `Sources/Zero/SyntaxHighlightedText.swift`): the
  tokenize-and-color logic extracted out of `FilePreviewView` into one shared place, used by both
  it and `DiffView`'s row rendering (`ToolCallCell.swift`) — a code file looks the same whether
  it's being read straight or being diffed, and a tool call's edit gets syntax highlighting for
  free as a side effect of the same reuse. Layered on top of, not instead of, `DiffView`'s existing
  monochrome added/removed tint: the tint is a whole-line background wash, the token color is
  per-character foreground — different visual layers, which is why the combination doesn't read as
  noisy the way stacking two foreground treatments would. This is the same pairing every mainstream
  diff-with-highlighting view already uses, not a new idiom invented here.
