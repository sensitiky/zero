import SwiftUI
import ZeroCore

/// Turns Foundation's markdown parsing into `Text`, in both the shapes this app needs: one line for
/// the sidebar, and a full body for the transcript.
///
/// No third-party renderer. `AttributedString(markdown:)` covers bold, italic, inline code, strike-
/// through and links out of the box — `Text` already knows how to draw those attributes — which is
/// everything a provider's replies actually use. What it does not give for free is fenced code
/// blocks and headings as distinct blocks, so `MarkdownBody` below does a small line-based split for
/// those two cases and lets Foundation handle every inline run inside each block.

/// One line, inline styling only — a session title or its dimmed summary. Never multi-line: both
/// callers already bound the source to one line before this ever sees it.
struct MarkdownText: View {
    let text: String

    init(text: String) { self.text = text }

    var body: some View {
        Text(styledInline(text))
    }
}

/// `Markdown.inline`, with link color overridden to fit the palette.
///
/// A link's default presentation is the system blue. This palette has exactly two colors, and a
/// provider's reply linking to a URL is not grounds for a third — the underline is what says "this
/// is a link," matching how the rest of the app already tells things apart by shape, not hue. The
/// override needs SwiftUI's attribute scope, which is why it lives here and not in `ZeroCore`.
func styledInline(_ text: String) -> AttributedString {
    var attributed = Markdown.inline(text)
    for run in attributed.runs where run.link != nil {
        attributed[run.range].foregroundColor = nil
        attributed[run.range].underlineStyle = .single
    }
    return attributed
}

/// A full message body: headings, fenced code blocks, and inline-styled paragraphs.
struct MarkdownBody: View {
    let text: String

    init(text: String) { self.text = text }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(styledInline(content))
                        .font(level <= 1 ? .title3.weight(.semibold) : .headline)
                        .textSelection(.enabled)

                case .code(let language, let content):
                    CodeBlock(language: language, content: content)

                case .paragraph(let content):
                    Text(styledInline(content))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A fenced code block, styled like every other code surface in the app — `ToolCallCell`, `DiffView`
/// — rather than inventing a fourth look for the same kind of content.
private struct CodeBlock: View {
    let language: String?
    let content: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            }
            Text(content)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.foreground(scheme).opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.foreground(scheme).opacity(0.12), lineWidth: 1)
                )
        }
    }
}
