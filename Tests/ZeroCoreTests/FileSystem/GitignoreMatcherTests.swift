import Testing

@testable import ZeroCore

@Suite("GitignoreMatcher")
struct GitignoreMatcherTests {
    @Test("an exact name matches at any depth")
    func exactNameAnyDepth() {
        let matcher = GitignoreMatcher(patterns: "node_modules")
        #expect(matcher.matches(relativePath: "node_modules", isDirectory: true))
        #expect(matcher.matches(relativePath: "packages/app/node_modules", isDirectory: true))
        #expect(!matcher.matches(relativePath: "not_node_modules", isDirectory: true))
    }

    @Test("a * glob matches by suffix at any depth")
    func globSuffixAnyDepth() {
        let matcher = GitignoreMatcher(patterns: "*.log")
        #expect(matcher.matches(relativePath: "debug.log", isDirectory: false))
        #expect(matcher.matches(relativePath: "logs/nested/debug.log", isDirectory: false))
        #expect(!matcher.matches(relativePath: "debug.log.txt", isDirectory: false))
    }

    @Test("a trailing slash matches directories only")
    func directoryOnly() {
        let matcher = GitignoreMatcher(patterns: "dist/")
        #expect(matcher.matches(relativePath: "dist", isDirectory: true))
        #expect(!matcher.matches(relativePath: "dist", isDirectory: false))
    }

    @Test("an interior slash is root-relative, not any-depth")
    func rootRelative() {
        let matcher = GitignoreMatcher(patterns: "src/generated")
        #expect(matcher.matches(relativePath: "src/generated", isDirectory: true))
        #expect(!matcher.matches(relativePath: "other/src/generated", isDirectory: true))
        #expect(!matcher.matches(relativePath: "generated", isDirectory: true))
    }

    @Test("a leading **/ makes an otherwise root-relative pattern match at any depth")
    func doubleStarAnyDepth() {
        let matcher = GitignoreMatcher(patterns: "**/fixtures/*.json")
        #expect(matcher.matches(relativePath: "fixtures/a.json", isDirectory: false))
        #expect(matcher.matches(relativePath: "deep/nested/fixtures/a.json", isDirectory: false))
        #expect(!matcher.matches(relativePath: "fixtures/a.txt", isDirectory: false))
    }

    @Test("comments and blank lines are skipped")
    func commentsAndBlankLinesSkipped() {
        let matcher = GitignoreMatcher(patterns: "# a comment\n\n  \nbuild\n")
        #expect(matcher.matches(relativePath: "build", isDirectory: true))
        #expect(!matcher.matches(relativePath: "# a comment", isDirectory: false))
    }

    @Test("negation is not supported — documents the gap rather than silently half-supporting it")
    func negationNotSupported() {
        // A real gitignore parser would un-ignore *.log inside keep/. This one has no concept of
        // negation, so the earlier *.log pattern still wins — keep/important.log stays hidden.
        let matcher = GitignoreMatcher(patterns: "*.log\n!keep/important.log")
        #expect(matcher.matches(relativePath: "keep/important.log", isDirectory: false))
    }

    @Test("an empty matcher matches nothing")
    func emptyMatchesNothing() {
        #expect(!GitignoreMatcher.empty.matches(relativePath: "anything", isDirectory: false))
    }
}
