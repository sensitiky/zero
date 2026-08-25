import Foundation
import Testing
@testable import ZeroCore

@Suite("ComposerMetrics")
struct ComposerMetricsTests {

    @Test("every width SwiftUI can propose survives the character budget")
    func characterBudgetSurvivesAnyWidth() {
        // The crash: SwiftUI probes a flexible child with an infinite width, and `Int(.infinity)`
        // traps. Same for NaN and for a width so large the division still overflows `Int`.
        #expect(ComposerMetrics.charactersPerLine(forWidth: .infinity)
            == Int(ComposerMetrics.unboundedWidth / 3))
        #expect(ComposerMetrics.charactersPerLine(forWidth: .greatestFiniteMagnitude)
            == Int(ComposerMetrics.unboundedWidth / 3))
        #expect(ComposerMetrics.charactersPerLine(forWidth: .nan) == 20)
        #expect(ComposerMetrics.charactersPerLine(forWidth: 0) == 20)
        #expect(ComposerMetrics.charactersPerLine(forWidth: -1) == 20)
        // A real composer width still gets a generous, wrapping-safe budget.
        #expect(ComposerMetrics.charactersPerLine(forWidth: 600) == 200)
    }

    @Test("a draft shorter than the bound is returned whole")
    func shortDraftIsWhole() {
        let draft = "Reply to this."
        #expect(ComposerMetrics.heightDeterminingPrefix(of: draft, maxLines: 10) == draft[...])
    }

    @Test("an empty draft yields an empty prefix")
    func emptyDraft() {
        #expect(ComposerMetrics.heightDeterminingPrefix(of: "", maxLines: 10).isEmpty)
    }

    @Test("the prefix is bounded by characters, so it does not grow with the draft")
    func boundedByCharacters() {
        // The bug in one assertion: these two differ by 190 000 characters and must measure
        // the same amount of text.
        let small = String(repeating: "a", count: 10_000)
        let huge = String(repeating: "a", count: 200_000)
        let a = ComposerMetrics.heightDeterminingPrefix(of: small, maxLines: 10, charactersPerLine: 160)
        let b = ComposerMetrics.heightDeterminingPrefix(of: huge, maxLines: 10, charactersPerLine: 160)
        #expect(a.count == 1_600)
        #expect(b.count == 1_600)
        #expect(a.count == b.count)
    }

    @Test("newlines end the walk early — ten hard lines need no character budget")
    func newlinesStopEarly() {
        let draft = String(repeating: "x\n", count: 5_000)
        let prefix = ComposerMetrics.heightDeterminingPrefix(of: draft, maxLines: 10)
        // Ten newlines fill the field; the prefix stops at the tenth, not at the budget.
        #expect(prefix.filter { $0 == "\n" }.count == 10)
        #expect(prefix.count == 20)
    }

    @Test("a draft with exactly maxLines newlines keeps all of them")
    func exactlyMaxLines() {
        let draft = "1\n2\n3"
        let prefix = ComposerMetrics.heightDeterminingPrefix(of: draft, maxLines: 3)
        #expect(prefix.filter { $0 == "\n" }.count == 2)
        #expect(prefix == draft[...])
    }

    @Test("the prefix never splits a grapheme cluster")
    func graphemeSafe() {
        // Family emoji: multi-scalar clusters. A byte-wise cut would corrupt one; Substring
        // indices cannot.
        let draft = String(repeating: "👨‍👩‍👧‍👦", count: 5_000)
        let prefix = ComposerMetrics.heightDeterminingPrefix(of: draft, maxLines: 2, charactersPerLine: 10)
        #expect(prefix.count == 20)
        #expect(prefix.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        #expect(String(prefix).unicodeScalars.count == 20 * "👨‍👩‍👧‍👦".unicodeScalars.count)
    }

    @Test("the prefix is always a prefix of the draft")
    func isAPrefix() {
        for draft in ["", "short", String(repeating: "word ", count: 9_000), "a\nb\nc\n\n\nd"] {
            let prefix = ComposerMetrics.heightDeterminingPrefix(of: draft, maxLines: 10)
            #expect(draft.hasPrefix(prefix))
        }
    }
}
