import Foundation
import Testing

@testable import ZeroCore

@Suite("FileDiff")
struct FileDiffTests {
    /// Compact rendering of a hunk, so a test can assert the whole shape in one `#expect` instead of
    /// indexing into it line by line. `−`/`+`/` ` marker, then the two line numbers.
    private func render(_ diff: FileDiff) -> [String] {
        diff.hunks.flatMap { hunk in
            hunk.lines.map { line in
                let marker = switch line.kind {
                case .removed: "−"
                case .added: "+"
                case .context: " "
                }
                let old = line.oldLine.map(String.init) ?? "·"
                let new = line.newLine.map(String.init) ?? "·"
                return "\(marker)\(old),\(new) \(line.text)"
            }
        }
    }

    // MARK: - Interleaving

    @Test("a changed line is removed and added in place, not old block then new block")
    func changeIsInterleaved() {
        let diff = FileDiff(
            edit: FileEdit(
                path: "a.swift",
                oldText: "one\ntwo\nthree",
                newText: "one\nTWO\nthree"
            )
        )
        #expect(diff.shape == .comparison)
        #expect(render(diff) == [
            " 1,1 one",
            "−2,· two",
            "+·,2 TWO",
            " 3,3 three",
        ])
    }

    @Test("line numbers advance independently on each side")
    func lineNumbersPerSide() {
        let diff = FileDiff(
            edit: FileEdit(
                path: "a.swift",
                oldText: "a\nb\nc",
                newText: "a\nx\ny\nb\nc"
            )
        )
        #expect(render(diff) == [
            " 1,1 a",
            "+·,2 x",
            "+·,3 y",
            " 2,4 b",
            " 3,5 c",
        ])
    }

    @Test("a pure deletion keeps the surrounding context on both sides")
    func pureDeletion() {
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: "a\nb\nc", newText: "a\nc")
        )
        #expect(render(diff) == [
            " 1,1 a",
            "−2,· b",
            " 3,2 c",
        ])
    }

    // MARK: - Hunks

    @Test("an unchanged run longer than twice the context is split into separate hunks")
    func longRunSplitsHunks() {
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...40).map { "line \($0)" }
        newLines[2] = "CHANGED 3"
        newLines[37] = "CHANGED 38"
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: old, newText: newLines.joined(separator: "\n"))
        )
        #expect(diff.hunks.count == 2)
        // Three lines of context each side, clamped by the file: the change is on line 3, so only
        // two lines exist above it. Two context, the removal and the addition, three context.
        #expect(diff.hunks[0].oldStart == 1)
        #expect(diff.hunks[0].lines.count == 7)
        #expect(diff.hunks[1].oldStart == 35)
        #expect(!render(diff).contains { $0.hasSuffix("line 20") })
    }

    @Test("changes closer together than the context window stay in one hunk")
    func nearbyChangesShareAHunk() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...20).map { "line \($0)" }
        newLines[9] = "CHANGED 10"
        newLines[12] = "CHANGED 13"
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: old, newText: newLines.joined(separator: "\n"))
        )
        #expect(diff.hunks.count == 1)
    }

    @Test("hunk counts describe how many lines each side contributes")
    func hunkCounts() {
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: "a\nb\nc", newText: "a\nx\ny\nb\nc")
        )
        let hunk = try! #require(diff.hunks.first)
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 5)
    }

    // MARK: - The Write case and other edges

    @Test("no old text is a whole file, not a diff against nothing")
    func writeIsWholeFile() {
        let diff = FileDiff(edit: FileEdit(path: "new.swift", newText: "a\nb"))
        #expect(diff.shape == .wholeFile)
        #expect(render(diff) == ["+·,1 a", "+·,2 b"])
    }

    @Test("empty old text is a whole file too, since there is nothing to compare against")
    func emptyOldTextIsWholeFile() {
        let diff = FileDiff(edit: FileEdit(path: "new.swift", oldText: "", newText: "a"))
        #expect(diff.shape == .wholeFile)
    }

    @Test("identical texts produce no hunks at all")
    func identicalTextsAreEmpty() {
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: "a\nb\nc", newText: "a\nb\nc")
        )
        #expect(diff.shape == .comparison)
        #expect(diff.hunks.isEmpty)
        #expect(diff.isEmpty)
    }

    @Test("an edit with neither side is empty rather than a crash")
    func noTextAtAll() {
        let diff = FileDiff(edit: FileEdit(path: "a.swift"))
        #expect(diff.hunks.isEmpty)
        #expect(diff.isEmpty)
    }

    @Test("a trailing newline is a final empty line on both sides, not a phantom change")
    func trailingNewline() {
        let diff = FileDiff(
            edit: FileEdit(path: "a.swift", oldText: "a\nb\n", newText: "a\nb\n")
        )
        #expect(diff.hunks.isEmpty)
    }

    @Test("the path comes through untouched")
    func pathPreserved() {
        let diff = FileDiff(edit: FileEdit(path: "Sources/A/B.swift", newText: "x"))
        #expect(diff.path == "Sources/A/B.swift")
    }

    // MARK: - Cost

    @Test("a large file with one change stays well inside a frame budget")
    func largeFileCost() {
        let old = (1...4_000).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...4_000).map { "line \($0)" }
        newLines[2_000] = "CHANGED"
        let new = newLines.joined(separator: "\n")

        let started = Date()
        let diff = FileDiff(edit: FileEdit(path: "big.swift", oldText: old, newText: new))
        let elapsed = Date().timeIntervalSince(started)

        #expect(diff.hunks.count == 1)
        // The diff is computed once per edit and cached, never in `body` — but even so, a 4k-line
        // file with one change must not be anywhere near a dropped frame.
        #expect(elapsed < 0.5, "took \(elapsed)s")
    }
}
