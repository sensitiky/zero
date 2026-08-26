import Testing

@testable import ZeroCore

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    @Test("recognized code extensions resolve a comment style; prose does not")
    func isCodeFile() {
        #expect(SyntaxHighlighter.isCodeFile(named: "App.swift"))
        #expect(SyntaxHighlighter.isCodeFile(named: "script.py"))
        #expect(SyntaxHighlighter.isCodeFile(named: "config.json"))
        #expect(!SyntaxHighlighter.isCodeFile(named: "README.md"))
        #expect(!SyntaxHighlighter.isCodeFile(named: "notes.txt"))
        #expect(!SyntaxHighlighter.isCodeFile(named: "mystery.xyz"))
    }

    @Test("a keyword is tokenized as .keyword, a plain identifier is not")
    func keywordVsIdentifier() {
        let tokens = SyntaxHighlighter.tokenize("return value", commentStyle: .slashSlash)
        #expect(tokens.contains(Token("return", .keyword)))
        #expect(tokens.contains(Token("value", .plain)))
    }

    @Test("a double-quoted string is one token, backslash-escaped quote doesn't end it early")
    func stringToken() {
        let tokens = SyntaxHighlighter.tokenize(#"let s = "a \" b""#, commentStyle: .slashSlash)
        #expect(tokens.contains(Token(#""a \" b""#, .string)))
    }

    @Test("// starts a slashSlash comment that runs to end of line")
    func slashSlashComment() {
        let tokens = SyntaxHighlighter.tokenize("let x = 1 // trailing note", commentStyle: .slashSlash)
        #expect(tokens.contains(Token("// trailing note", .comment)))
    }

    @Test("# does not start a comment under slashSlash style — #available stays a plain word")
    func hashIsNotCommentUnderSlashSlash() {
        let tokens = SyntaxHighlighter.tokenize("#available(macOS 26, *)", commentStyle: .slashSlash)
        #expect(!tokens.contains { $0.kind == .comment })
    }

    @Test("# starts a comment under hash style")
    func hashComment() {
        let tokens = SyntaxHighlighter.tokenize("x = 1  # note", commentStyle: .hash)
        #expect(tokens.contains(Token("# note", .comment)))
    }

    @Test("a numeric literal is tokenized as .number")
    func numberToken() {
        let tokens = SyntaxHighlighter.tokenize("let x = 3.14", commentStyle: .slashSlash)
        #expect(tokens.contains(Token("3.14", .number)))
    }

    @Test("plain text with no recognized syntax stays entirely .plain")
    func plainTextStaysPlain() {
        let tokens = SyntaxHighlighter.tokenize("just some words here", commentStyle: .noComments)
        #expect(tokens.allSatisfy { $0.kind == .plain })
    }
}

private func Token(_ text: String, _ kind: SyntaxHighlighter.TokenKind) -> SyntaxHighlighter.Token {
    SyntaxHighlighter.Token(text: text, kind: kind)
}
