import Foundation
import Testing

@testable import ZeroCore

@Suite("Markdown")
struct MarkdownTests {
    // MARK: - Block splitting

    @Test("plain text is one paragraph")
    func plainTextIsOneParagraph() {
        let blocks = Markdown.blocks(of: "just a sentence.")
        #expect(blocks == [.paragraph(text: "just a sentence.")])
    }

    @Test("a fenced code block is its own block, with the language captured")
    func fencedCodeBlockIsSeparate() {
        let markdown = "before\n```swift\nlet x = 1\n```\nafter"
        let blocks = Markdown.blocks(of: markdown)
        #expect(blocks == [
            .paragraph(text: "before"),
            .code(language: "swift", text: "let x = 1"),
            .paragraph(text: "after"),
        ])
    }

    @Test("a fence with no language yields a nil language, not an empty string")
    func fenceWithNoLanguage() {
        let blocks = Markdown.blocks(of: "```\nplain\n```")
        #expect(blocks == [.code(language: nil, text: "plain")])
    }

    @Test("an unterminated fence still surfaces its content")
    func unterminatedFenceStillShowsContent() {
        // Mid-stream, the closing ``` may not have arrived yet. Losing the block until it does
        // would be worse than showing it without the fence's styling settled.
        let blocks = Markdown.blocks(of: "```swift\nlet x = 1")
        #expect(blocks == [.code(language: "swift", text: "let x = 1")])
    }

    @Test("a heading is split out at every level, and the hashes are stripped")
    func headingLevelsAreDetected() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let blocks = Markdown.blocks(of: "\(hashes) Title")
            #expect(blocks == [.heading(level: level, text: "Title")], "level \(level)")
        }
    }

    @Test("a 7th-level heading is not a heading — six hashes is CommonMark's ceiling")
    func sevenHashesIsNotAHeading() {
        let blocks = Markdown.blocks(of: "####### not a heading")
        #expect(blocks == [.paragraph(text: "####### not a heading")])
    }

    @Test("a hash with no following space is not a heading")
    func hashWithoutSpaceIsNotAHeading() {
        // Distinguishes a heading from a hashtag-shaped word or a code comment pasted as prose.
        let blocks = Markdown.blocks(of: "#nospace")
        #expect(blocks == [.paragraph(text: "#nospace")])
    }

    @Test("consecutive lines with no blank line between them are one paragraph")
    func consecutiveLinesJoinIntoOneParagraph() {
        let blocks = Markdown.blocks(of: "line one\nline two")
        #expect(blocks == [.paragraph(text: "line one\nline two")])
    }

    @Test("a blank line separates two paragraphs")
    func blankLineSeparatesParagraphs() {
        let blocks = Markdown.blocks(of: "first\n\nsecond")
        #expect(blocks == [.paragraph(text: "first"), .paragraph(text: "second")])
    }

    @Test("a fence inside what looks like a paragraph still splits correctly")
    func fenceAdjacentToParagraphSplitsCleanly() {
        let blocks = Markdown.blocks(of: "```js\nconsole.log(1)\n```\n```py\nprint(1)\n```")
        #expect(blocks == [
            .code(language: "js", text: "console.log(1)"),
            .code(language: "py", text: "print(1)"),
        ])
    }

    @Test("empty input yields no blocks")
    func emptyInputYieldsNoBlocks() {
        #expect(Markdown.blocks(of: "").isEmpty)
    }

    // MARK: - Inline parsing

    @Test("inline parsing never throws outward — malformed markdown still renders as text")
    func inlineNeverThrows() {
        // AttributedString(markdown:) can throw on some malformed input; the fallback is the
        // fact under test, not any particular string shape.
        let result = Markdown.inline("**unterminated bold and a [broken link](")
        #expect(String(result.characters) == "**unterminated bold and a [broken link](")
    }

    @Test("bold, code and links parse into distinct runs")
    func inlineStylingParsesIntoRuns() {
        let result = Markdown.inline("this is **bold**, `code`, and a [link](https://example.com)")
        let runs = Array(result.runs)
        #expect(runs.count > 1, "single-run output means nothing was actually parsed as markdown")

        let hasLink = runs.contains { $0.link?.absoluteString == "https://example.com" }
        #expect(hasLink)
    }

    @Test("plain text with no markdown syntax round-trips unchanged")
    func plainTextRoundTrips() {
        let text = "nothing special here"
        #expect(String(Markdown.inline(text).characters) == text)
    }

    // MARK: - Sidebar single-line contexts: headings have nowhere to render as a block

    @Test("a leading heading marker is stripped for single-line contexts")
    func headingMarkerIsStripped() {
        #expect(Markdown.strippingHeadingMarker("# Test") == "Test")
        #expect(Markdown.strippingHeadingMarker("### Deep heading") == "Deep heading")
    }

    @Test("text with no heading marker passes through unchanged")
    func noHeadingMarkerPassesThrough() {
        #expect(Markdown.strippingHeadingMarker("Fix bug #42") == "Fix bug #42")
        #expect(Markdown.strippingHeadingMarker("plain text") == "plain text")
    }

    @Test("a bare hash with no following space is not treated as a heading")
    func bareHashIsNotAHeading() {
        #expect(Markdown.strippingHeadingMarker("#nospace") == "#nospace")
    }

    // MARK: - Safety: oversized input
    //
    // docs/bugs/014-transcript-huge-message-hang: a session whose first message was 247,142
    // characters (the whole prior transcript, seeded and sent by the 010-provider-handoff
    // composer) hung the app on launch — the message survived as one uncapped block, and
    // CoreText never returned from laying it out as a single `Text`. Nothing downstream of
    // `blocks(of:)` may see a block that large.

    @Test("a pathologically large single-block message is capped, not handed whole to text layout")
    func hugeMessageIsCapped() {
        let huge = String(repeating: "a", count: 300_000)
        let blocks = Markdown.blocks(of: huge)
        let longest = blocks.map { block -> Int in
            switch block {
            case .heading(_, let text), .paragraph(let text): text.count
            case .code(_, let text): text.count
            }
        }.max() ?? 0
        #expect(longest < 300_000, "a 300k-char message must not survive as one uncapped block")
    }
}
