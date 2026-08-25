import Foundation

/// How much of a draft can possibly affect the size of a field that stops growing.
///
/// A composer capped at ten lines is exactly as tall for a 200-character draft that overflows those
/// lines as for a 200 000-character one. Measuring the whole draft to decide the height is therefore
/// work whose answer cannot change — and it was the cause of `docs/bugs/004-composer-input-lag`:
/// SwiftUI asked the field for its size twice per display cycle, and the field answered by having
/// CoreText shape and kern the entire text.
public enum ComposerMetrics {

    /// The composer grows to this many lines and then stops. It lives here, beside the bound it
    /// feeds, rather than in the view — `Composer` is generic over its trailing control, and a
    /// generic type cannot hold a static stored property.
    public static let maxLines = 10

    /// Stands in for a width the composer will not measure text at: what it answers when a stack
    /// asks how much room it would take, and the ceiling on any width it does measure at. Wider
    /// than any display, and small enough that the budget below stays ordinary arithmetic.
    public static let unboundedWidth: CGFloat = 10_000

    /// The `charactersPerLine` budget for a field laid out at `width`, estimated at three points a
    /// character — an over-count for the body font, which is the safe direction (see below).
    ///
    /// Every width SwiftUI can propose has to survive this conversion, and two of them are not
    /// numbers to divide: it probes a flexible child with `.infinity`, and `Int(.infinity)`,
    /// `Int(.nan)` and `Int(.greatestFiniteMagnitude / 3)` all trap. That trap crashed the app on
    /// the first layout of the composer, so the clamp lives here, next to the budget it feeds,
    /// rather than at the one call site.
    public static func charactersPerLine(forWidth width: CGFloat) -> Int {
        // NaN loses every comparison, so this catches it along with zero and negative widths.
        guard width > 0 else { return minimumCharactersPerLine }
        return max(minimumCharactersPerLine, Int(min(width, unboundedWidth) / 3))
    }

    /// A hairline-narrow box still gets a prefix worth measuring.
    private static let minimumCharactersPerLine = 20

    /// The leading slice of `draft` that is enough to decide the height of a field capped at
    /// `maxLines`, or the whole draft when it is shorter than that.
    ///
    /// Two things can end a line: a hard newline, or enough characters to wrap. So the walk stops at
    /// whichever comes first — `maxLines` newlines, or `charactersPerLine * maxLines` characters.
    /// Both bounds are constant, which is the whole point: the result never grows with the draft.
    ///
    /// `charactersPerLine` is deliberately generous. Getting it too high costs a few hundred
    /// characters of measurement; too low would under-report the height and clip a line, so it errs
    /// upward. It is a knob rather than a constant because the right value depends on the font and
    /// the measure the field is laid out at, which this type cannot see.
    public static func heightDeterminingPrefix(
        of draft: String,
        maxLines: Int,
        charactersPerLine: Int = 160
    ) -> Substring {
        precondition(maxLines > 0, "a field that can show no lines has no height to determine")
        precondition(charactersPerLine > 0)

        let characterBudget = maxLines * charactersPerLine
        var newlines = 0
        var counted = 0
        var index = draft.startIndex

        while index < draft.endIndex {
            if counted >= characterBudget { break }
            if draft[index] == "\n" {
                newlines += 1
                // Stop *after* the newline that completes the last visible line: the field is
                // already full, and nothing beyond it can make the field taller.
                if newlines >= maxLines {
                    return draft[draft.startIndex...index]
                }
            }
            counted += 1
            index = draft.index(after: index)
        }
        return draft[draft.startIndex..<index]
    }
}
