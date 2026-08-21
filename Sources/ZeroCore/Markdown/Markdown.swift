import Foundation

/// The parsing this app needs from markdown text, kept in one place so both views draw from it.
public enum Markdown {
    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case code(language: String?, text: String)
        case paragraph(text: String)
    }

    /// Inline styling only: bold, italic, code spans, strikethrough, links. Never throws outward —
    /// malformed markdown falls back to the text verbatim rather than showing nothing.
    /// Cheap pre-check so a caller can skip parsing entirely for plain text — the common case for a
    /// tool notice, a session title, or a reply with no formatting at all.
    public static func mightContainSyntax(_ text: String) -> Bool {
        text.contains(where: { "*_`#[]".contains($0) })
    }

    /// Parses to `AttributedString`, never throwing outward: malformed markdown falls back to the
    /// text verbatim rather than showing nothing.
    ///
    /// This is Foundation-only on purpose — no `import SwiftUI` in this file — so it stays testable
    /// in `ZeroCoreTests`. Overriding a link's color to fit the two-token palette needs SwiftUI's
    /// own attribute scope; that step lives in the `Zero` view layer, right where the rendering does.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }

    /// Splits into headings, fenced code blocks, and paragraphs. Deliberately not a full CommonMark
    /// parser: lists and blockquotes pass through as plain paragraph text, which reads fine — the
    /// two things that render outright broken without this split are literal ``` fences and stray
    /// `#` characters, and those are what this handles.
    public static func blocks(of markdown: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(text: paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for substring in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)

            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let label = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = label.isEmpty ? nil : label
                }
                continue
            }

            if inCode {
                codeLines.append(line)
                continue
            }

            if let level = headingLevel(of: line) {
                flushParagraph()
                let content = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: level, text: content))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            paragraph.append(line)
        }

        // An unterminated fence still shows what streamed in so far — mid-stream, a code block's
        // closing ``` may not have arrived yet, and losing the content until it does would be worse.
        if inCode {
            result.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return result
    }

    private static func headingLevel(of line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6,
              line.count > hashes.count,
              line[line.index(line.startIndex, offsetBy: hashes.count)] == " "
        else { return nil }
        return hashes.count
    }
}
