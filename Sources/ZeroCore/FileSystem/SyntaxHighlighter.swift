import Foundation

/// A small, dependency-free tokenizer for the file preview's syntax highlighting (FR-6,
/// `docs/prds/007-file-tree-sidebar/PRD.md` — added after Gate 3 at the user's explicit request,
/// reversing that PRD's original monochrome-only preview).
///
/// Not per-language grammars — one generic scanner (comment / string / number / keyword) shared
/// across every recognized language, with only its comment style varying. Good enough for how
/// code actually gets glanced at in a preview pane; a real editor's highlighter this is not, and
/// isn't trying to be.
public enum SyntaxHighlighter {
    public enum TokenKind: Sendable, Equatable {
        case plain, keyword, string, comment, number
    }

    public struct Token: Sendable, Equatable {
        public let text: String
        public let kind: TokenKind
    }

    public enum CommentStyle: Sendable {
        case slashSlash
        case hash
        /// A recognized code language with no line-comment syntax to scan for (JSON, XML) — not
        /// named `.none`: that collides with `Optional<CommentStyle>.none` (nil) at every call
        /// site returning `CommentStyle?`, which is exactly the bug this rename exists to avoid —
        /// `return .none` in that context silently means "return nil", not "return this case".
        case noComments
    }

    /// Whether `name`'s extension is worth tokenizing at all, and if so, which line-comment
    /// syntax it uses. `nil` means "preview as plain text" — markdown, plain text, and anything
    /// unrecognized stay exactly as they were before this existed (PRD Non-goals: highlighting
    /// only fires for recognized code, never prose).
    public static func commentStyle(forFileNamed name: String) -> CommentStyle? {
        let ext = (name as NSString).pathExtension.lowercased()
        if slashSlashExtensions.contains(ext) { return .slashSlash }
        if hashExtensions.contains(ext) { return .hash }
        if noneExtensions.contains(ext) { return .noComments }
        return nil
    }

    public static func isCodeFile(named name: String) -> Bool {
        commentStyle(forFileNamed: name) != nil
    }

    private static let slashSlashExtensions: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "java", "kt", "c", "h", "cpp", "hpp", "go", "rs",
    ]
    private static let hashExtensions: Set<String> = ["py", "rb", "sh", "yml", "yaml", "toml"]
    private static let noneExtensions: Set<String> = ["json", "xml"]

    /// Keywords shared across the languages above — a common core (control flow, declarations,
    /// literals) rather than one list per language. A keyword particular to one language that
    /// happens to also be an identifier in another (rare, and cosmetic when it happens) is the
    /// trade for one list instead of a dozen.
    private static let keywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "func", "function", "def", "class", "struct", "enum", "protocol", "extension",
        "interface", "trait", "impl", "import", "from", "package", "module", "export",
        "let", "var", "const", "val", "final", "static", "public", "private", "protected",
        "internal", "fileprivate", "open", "override", "mutating", "async", "await", "throws",
        "throw", "try", "catch", "finally", "guard", "self", "this", "super", "init", "new",
        "delete", "null", "nil", "None", "true", "false", "True", "False", "void", "typealias",
        "type", "namespace", "using", "in", "is", "as", "and", "or", "not", "lambda", "yield",
    ]

    /// Tokenizes one line. Line-at-a-time on purpose: block comments (`/* */`) that span lines
    /// aren't attempted — a known, stated simplification, not a silent gap.
    public static func tokenize(_ line: String, commentStyle: CommentStyle) -> [Token] {
        let chars = Array(line)
        var tokens: [Token] = []
        var plain = ""
        var i = 0

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(Token(text: plain, kind: .plain))
                plain = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            if isCommentStart(chars, at: i, style: commentStyle) {
                flushPlain()
                tokens.append(Token(text: String(chars[i...]), kind: .comment))
                break
            }

            if c == "\"" || c == "'" {
                flushPlain()
                var j = i + 1
                while j < chars.count {
                    if chars[j] == c && chars[j - 1] != "\\" { j += 1; break }
                    j += 1
                }
                tokens.append(Token(text: String(chars[i..<j]), kind: .string))
                i = j
                continue
            }

            if c.isNumber {
                flushPlain()
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                tokens.append(Token(text: String(chars[i..<j]), kind: .number))
                i = j
                continue
            }

            if c.isLetter || c == "_" {
                flushPlain()
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                tokens.append(Token(text: word, kind: keywords.contains(word) ? .keyword : .plain))
                i = j
                continue
            }

            plain.append(c)
            i += 1
        }

        flushPlain()
        return tokens
    }

    private static func isCommentStart(_ chars: [Character], at i: Int, style: CommentStyle) -> Bool {
        switch style {
        case .slashSlash:
            return chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "/"
        case .hash:
            return chars[i] == "#"
        case .noComments:
            return false
        }
    }
}
