import SwiftUI
import ZeroCore

/// A file's contents, read-only.
///
/// For a file with uncommitted changes (`gitStatus`), shows a real diff against `HEAD` — "inside
/// the file itself" gets the same diff indicator the tree row does. For anything unchanged, it's
/// numbered monospace text, syntax-highlighted for a recognized code extension
/// (`SyntaxHighlighter`), plain for anything else (markdown, plain text, unknown).
///
/// The diff path reuses `DiffView`/`FileDiff` outright — the same component `ToolCallCell` already
/// renders a tool call's edit through — via a synthetic `FileEdit` (`oldText` from `HEAD`,
/// `newText` the file as it is now). It's syntax-highlighted too — `DiffView` and this view share
/// `SyntaxHighlightedText`, so a code file looks the same whether it's changed or not. The plain
/// path is not `DiffView` itself: that models hunks, gaps, and dual old/new columns, a diff's
/// shape, not a file's — this reuses only the same `Theme.code()` + gutter-number idiom and the
/// shared highlighter, without the comparison machinery.
///
/// A `LazyVStack` inside a `ScrollView` only renders the rows on screen, so this doesn't reproduce
/// `004-composer-input-lag` — that bug was an enclosing stack re-measuring a field's *total* size
/// on every layout pass, not a scrollable list rendering what's visible. `WorkspaceFileReader`'s
/// 1 MB ceiling bounds the worst case regardless, and so does tokenizing one line at a time rather
/// than the whole file at once.
struct FilePreviewView: View {
    let entry: WorkspaceEntry
    let root: URL
    /// This file's diff status, if any — `nil` for an unchanged file. Looked up by the caller
    /// (`FileTreePanel`, which already holds it in `FileTreeState`) rather than read again here.
    let gitStatus: GitFileStatus?
    let onBack: () -> Void

    @State private var content: WorkspaceFileReader.Content?
    /// Set only when `gitStatus != nil` and the file decoded as text — a synthetic edit built
    /// purely to hand to `DiffView`, not anything persisted or reported by an agent.
    @State private var diffEdit: FileEdit?
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: content)
        }
        // Off the main actor, same reasoning as `FileTreeRow`'s directory read. `GitService`'s own
        // calls are actor-isolated already — the `Task.detached` wrapping here is only for
        // `WorkspaceFileReader.read`, a plain (non-actor) function that would otherwise run
        // directly on whatever executor this `.task` started on.
        .task(id: entry.id) {
            content = nil
            diffEdit = nil
            let url = entry.url
            let root = root
            let read = try? await Task.detached {
                try WorkspaceFileReader.read(url, root: root)
            }.value
            content = read

            guard let gitStatus, case .text(let text) = read else { return }
            let relativePath = WorkspaceTree.relativePath(of: url, root: root)
            let headText: String?
            if gitStatus == .modified, let gitService = try? GitService(repositoryPath: root) {
                headText = await gitService.headContent(ofRelativePath: relativePath)
            } else {
                headText = nil // .added: no HEAD version to diff against — the whole file is new.
            }
            diffEdit = FileEdit(path: relativePath, oldText: headText, newText: text)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to file tree")

            Text(entry.name)
                .font(Theme.code(weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    @ViewBuilder
    private func body(for content: WorkspaceFileReader.Content?) -> some View {
        switch content {
        case .text(let text):
            ScrollView {
                if let diffEdit {
                    DiffView(edit: diffEdit)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    lines(of: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .binary(let bytes):
            placeholder("Binary file", detail: byteString(bytes))
        case .tooLarge(let bytes):
            placeholder("Too large to preview", detail: byteString(bytes))
        case nil:
            // No spinner: a read this size is expected to land before a frame would show one.
            Color.clear
        }
    }

    private func lines(of text: String) -> some View {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1)")
                        .font(Theme.code(.caption))
                        .foregroundStyle(Theme.secondary(scheme))
                        .monospacedDigit()
                        .frame(width: gutter, alignment: .trailing)
                        .textSelection(.disabled)
                    SyntaxHighlightedText.line(String(line), forFileNamed: entry.name, scheme: scheme)
                        .font(Theme.code())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
            }
        }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
