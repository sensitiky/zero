import Foundation

/// A `FileEdit` worked out into something readable: the two versions interleaved, each line carrying
/// its number on the side it exists on, grouped into hunks so an unchanged thousand lines between
/// two changes is not scrolled through.
///
/// Computed, never persisted — it is a projection of what the transcript already holds, so nothing
/// in `Store` or `Persistence` knows this type exists. It lives in `ZeroCore` rather than in the
/// view because it is the only part of the visual overhaul with logic worth testing, and testing it
/// through a SwiftUI view would mean not testing it.
public struct FileDiff: Sendable, Equatable {
    /// How many unchanged lines to keep on each side of a change. Three is what `diff -u` uses and
    /// what every reviewer's eye is trained on.
    public static let context = 3

    public enum Shape: Sendable, Equatable {
        /// Both versions are known, so the two can be compared.
        case comparison
        /// Only the new text is known — a `Write` reports no previous version. Shown as the file
        /// that was written, because comparing it against nothing would be inventing a diff.
        case wholeFile
    }

    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case context, removed, added
        }

        public var kind: Kind
        public var text: String
        /// Its number in the previous version, or `nil` if it does not exist there.
        public var oldLine: Int?
        /// Its number in the new version, or `nil` if it does not exist there.
        public var newLine: Int?

        public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
            self.kind = kind
            self.text = text
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    /// A run of changed lines plus the context around it. `oldStart`/`newStart` are 1-based, and are
    /// the line the hunk begins at on each side; for a hunk that only inserts, `oldStart` is the old
    /// line it was inserted after and `oldCount` is zero — the `@@ -N,0 +M,C @@` convention.
    public struct Hunk: Sendable, Equatable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        public var lines: [Line]
    }

    public let path: String
    public let shape: Shape
    public let hunks: [Hunk]

    public var isEmpty: Bool { hunks.isEmpty }

    public init(edit: FileEdit) {
        path = edit.path
        let new = Self.split(edit.newText)

        // A `Write` gives no previous version; so does an edit whose "previous" is the empty string,
        // which is the same statement said differently.
        guard let old = edit.oldText, !old.isEmpty else {
            shape = .wholeFile
            hunks = new.isEmpty ? [] : [
                Hunk(
                    oldStart: 0, oldCount: 0,
                    newStart: 1, newCount: new.count,
                    lines: new.enumerated().map {
                        Line(kind: .added, text: $0.element, oldLine: nil, newLine: $0.offset + 1)
                    }
                )
            ]
            return
        }

        shape = .comparison
        hunks = Self.group(Self.interleave(old: Self.split(old), new: new))
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Interleaving

    /// One list, in reading order, from the standard library's own difference.
    ///
    /// `CollectionDifference` reports removals and insertions as two flat sets of offsets, which is
    /// exactly the old-block-then-new-block shape this replaces. Walking both sides with those
    /// offsets in hand is what turns it back into something you read top to bottom: at each step the
    /// line is either gone from the old, new to the new, or the same in both.
    private static func interleave(old: [String], new: [String]) -> [Line] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var lines: [Line] = []
        lines.reserveCapacity(old.count + inserted.count)
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append(Line(kind: .removed, text: old[i], oldLine: i + 1, newLine: nil))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append(Line(kind: .added, text: new[j], oldLine: nil, newLine: j + 1))
                j += 1
            } else if i < old.count, j < new.count {
                // Neither removed nor inserted means the two sides matched here.
                lines.append(Line(kind: .context, text: old[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return lines
    }

    // MARK: - Hunks

    /// Keeps `context` lines either side of every change and drops the rest.
    ///
    /// Two changes merge into one hunk when the gap between them is small enough that splitting
    /// would print the same lines twice — which is the only reason the threshold is `2 * context`
    /// and not something tuned.
    private static func group(_ lines: [Line]) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        // Running totals, so a hunk that inserts before any old line can still say which old line it
        // follows without searching backwards for one.
        var oldBefore = [Int](repeating: 0, count: lines.count + 1)
        var newBefore = [Int](repeating: 0, count: lines.count + 1)
        for (index, line) in lines.enumerated() {
            oldBefore[index + 1] = oldBefore[index] + (line.oldLine == nil ? 0 : 1)
            newBefore[index + 1] = newBefore[index] + (line.newLine == nil ? 0 : 1)
        }

        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }

        return ranges.map { range in
            let slice = Array(lines[range])
            let oldCount = oldBefore[range.upperBound + 1] - oldBefore[range.lowerBound]
            let newCount = newBefore[range.upperBound + 1] - newBefore[range.lowerBound]
            return Hunk(
                // Where the hunk starts on each side. With no lines on a side, the count is zero and
                // the start is the line it sits after.
                oldStart: oldCount == 0 ? oldBefore[range.lowerBound] : oldBefore[range.lowerBound] + 1,
                oldCount: oldCount,
                newStart: newCount == 0 ? newBefore[range.lowerBound] : newBefore[range.lowerBound] + 1,
                newCount: newCount,
                lines: slice
            )
        }
    }
}
