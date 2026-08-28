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
///
/// Both views below cache their parse in `@State`, recomputed only via `.task(id: text)` — i.e. only
/// when `text` itself changes, never on an unrelated re-render. Parsing directly inside `body` was
/// the input lag that came back after markdown landed: the draft used to be local `@State` on
/// `ConversationPane`, so every keystroke re-evaluated its whole body, reconstructed
/// `TranscriptView`, and re-evaluated every entry's row — a plain `Text(styledInline(text))` in
/// `body` reparsed every message in the transcript on every keystroke, not just the one that
/// streamed. Caching by `text`'s own identity is what makes a re-render free again when nothing this
/// view actually shows has changed.
///
/// The keystroke half of that story is gone too: the draft now lives inside `Composer`, which is a
/// leaf, so typing no longer invalidates anything above it. The cache stays, because streaming still
/// changes one entry's text many times a second and the other entries must not pay for it.

/// One line, inline styling only — a session title or its dimmed summary. Never multi-line: both
/// callers already bound the source to one line before this ever sees it.
struct MarkdownText: View {
    let text: String
    @State private var attributed: AttributedString?

    init(text: String) { self.text = text }

    var body: some View {
        // The common case for a title or a one-line summary has no markdown syntax at all — the
        // plain-text branch skips the parse (and the flash of no styling before `.task` resolves)
        // entirely rather than pay for either.
        Group {
            if let attributed {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .task(id: text) {
            guard Markdown.mightContainSyntax(text) else {
                attributed = nil
                return
            }
            // A heading marker is block-level syntax with nowhere to render as a distinct block
            // in a one-line title or summary — strip it before inline parsing, or it shows up as a
            // literal "# " that the reader never asked to see.
            attributed = styledInline(Markdown.strippingHeadingMarker(text))
        }
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
    @State private var rendered: [RenderedBlock]?

    init(text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A block fades in as it arrives, so "still generating" is visible in the text itself
            // rather than needing a spinner beside it (FR-20.1). Keyed on how many blocks there are,
            // because that is what changes when a new one lands — the block being streamed into
            // grows in place and must not re-fade on every chunk.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(content)
                        .font(level <= 1 ? .title3.weight(.semibold) : .headline)
                        .textSelection(.enabled)

                case .code(let language, let content):
                    CodeBlock(language: language, content: content)

                case .paragraph(let content):
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .transition(.opacity)
        .zeroAnimation(Theme.Motion.arrival, value: blocks.count)
        .task(id: text) {
            rendered = Self.render(text)
        }
    }

    private var blocks: [RenderedBlock] {
        guard let rendered else {
            // The synchronous fallback before `.task` below has resolved — SwiftUI lays this out
            // on the very first render, so it must already be through `Markdown.blocks(of:)`'s
            // length cap (cheap: just a line split) rather than wrapping the raw `text` whole. A
            // pathologically large message reaching `Text` here, uncapped, is what hung the app
            // on launch before this: docs/bugs/014-transcript-huge-message-hang.
            return Markdown.blocks(of: text).map { block in
                switch block {
                case .heading(let level, let content):
                    .heading(level: level, text: AttributedString(content))
                case .code(let language, let content):
                    .code(language: language, text: content)
                case .paragraph(let content):
                    .paragraph(text: AttributedString(content))
                }
            }
        }
        return rendered
    }

    private enum RenderedBlock {
        case heading(level: Int, text: AttributedString)
        case code(language: String?, text: String)
        case paragraph(text: AttributedString)
    }

    private static func render(_ text: String) -> [RenderedBlock] {
        Markdown.blocks(of: text).map { block in
            switch block {
            case .heading(let level, let content):
                return .heading(level: level, text: styledInline(content))
            case .code(let language, let content):
                return .code(language: language, text: content)
            case .paragraph(let content):
                return .paragraph(text: styledInline(content))
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
                    .foregroundStyle(Theme.secondary(scheme))
            }
            Text(content)
                .font(Theme.code())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .zeroPanel(scheme, radius: Theme.Radius.content, elevation: .raised)
        }
    }
}
