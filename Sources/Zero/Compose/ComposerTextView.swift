import AppKit
import SwiftUI
import ZeroCore

/// The composer's editable text, as an `NSTextView` this app sizes itself.
///
/// It exists for one reason: **the size it reports must not depend on how long the draft is.**
/// SwiftUI's `TextField` cannot promise that — asked for its size it answers through
/// `NSTextFieldCell.cellSizeForBounds:`, which has CoreText shape and kern the entire text, and the
/// enclosing `HStack` asks between 3 and 16 times per layout pass, twice per display cycle. At 50 000
/// characters that saturated the main thread and showed the wait cursor
/// (`docs/bugs/004-composer-input-lag`). Pinning the height with `.frame(height:)` only removed the
/// *height* question; the stack still asked for the width, and the answer was still `O(draft)`.
///
/// Here `sizeThatFits` never touches more than a bounded prefix, so the question is cheap however
/// often it is asked. That is the whole justification for owning this view instead of using the
/// framework's field — everything else in this file is the cost of that ownership.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The composer grows to this many lines and then scrolls.
    let maxLines: Int
    /// Whether to take the keyboard on appear. The compose screen does; the reply composer does not
    /// steal focus from a conversation you are reading.
    let autofocus: Bool
    /// Spoken by VoiceOver. Not the placeholder — see `Composer.fieldLabel`.
    let accessibilityLabel: String
    let onSubmit: () -> Void
    /// Focus drives the composer's stroke, which is why it has to travel back up.
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusReportingTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = { focused in
            // Responder changes can land inside a SwiftUI update (the autofocus path below is one),
            // and writing state there is what SwiftUI warns about. One hop defers it past the update.
            Task { @MainActor in context.coordinator.parent.onFocusChange(focused) }
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)
        // The text starts at the leading edge with no padding of its own: the composer already owns
        // the insets, and the placeholder is positioned against this origin.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only when it actually differs: assigning `string` resets the selection, so doing it on
        // every update would fight the cursor while typing.
        if textView.string != text { textView.string = text }
        if textView.accessibilityLabel() != accessibilityLabel {
            textView.setAccessibilityLabel(accessibilityLabel)
        }
        if autofocus, !context.coordinator.didAutofocus {
            context.coordinator.didAutofocus = true
            // There is no window yet in `makeNSView`, and taking first responder during an update
            // would re-enter it.
            Task { @MainActor in scroll.window?.makeFirstResponder(textView) }
        }
    }

    /// The point of the whole file: bounded work, whatever the draft.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        switch proposal.width {
        // A nil width is an ideal-size query (the window's minimum comes from one). The box may be
        // narrow, so answer narrow rather than claiming the draft's natural width.
        case nil:
            return CGSize(width: 0, height: context.coordinator.lastHeight)
        // An infinite width is the stack working out how to share its space, asking how much the
        // composer would take: all of it. Nothing wraps at an unbounded measure, so there is
        // nothing to measure — and measuring anyway would put the draft back on the layout path,
        // once per pass. A SwiftUI size cannot be infinite either, so it comes back as a number.
        case let width? where !width.isFinite:
            return CGSize(width: ComposerMetrics.unboundedWidth, height: context.coordinator.lastHeight)
        case let width?:
            return CGSize(
                width: width,
                height: context.coordinator.height(of: text, width: width, maxLines: maxLines)
            )
        }
    }

    // MARK: - Height

    static let font = NSFont.preferredFont(forTextStyle: .body)

    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// How tall `prefix` is, clamped to `maxLines`. Costs ~0.3 ms and does not vary with the draft,
    /// because the caller only ever passes a bounded slice of it.
    static func measuredHeight(ofPrefix prefix: String, width: CGFloat, maxLines: Int) -> CGFloat {
        let bounds = (prefix as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = Int(ceil(bounds.height / lineHeight))
        return lineHeight * CGFloat(min(max(1, lines), maxLines))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var didAutofocus = false
        private var memo: (prefix: String, width: CGFloat, height: CGFloat)?

        /// The last height this view reported for a real width — the answer to give when the
        /// question does not come with one to measure at, so a probe cannot shrink the composer.
        var lastHeight: CGFloat { memo?.height ?? ComposerTextView.lineHeight }

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// The height of a field capped at `maxLines`, which is a function of a bounded prefix of the
        /// draft and nothing more.
        ///
        /// `heightDeterminingPrefix` returns either the whole draft — short enough that measuring it
        /// is cheap — or a slice long enough to overflow `maxLines` on its own, in which case the
        /// clamp decides the answer and what was cut off could not have changed it.
        ///
        /// Memoized because SwiftUI asks three times per layout pass with identical arguments, and
        /// every display cycle asks again: the caret blinking is enough to trigger one.
        func height(of text: String, width: CGFloat, maxLines: Int) -> CGFloat {
            guard width > 0, !text.isEmpty else { return ComposerTextView.lineHeight }
            let prefix = String(
                ComposerMetrics.heightDeterminingPrefix(
                    of: text,
                    maxLines: maxLines,
                    charactersPerLine: ComposerMetrics.charactersPerLine(forWidth: width)
                )
            )
            if let memo, memo.width == width, memo.prefix == prefix { return memo.height }
            let height = ComposerTextView.measuredHeight(ofPrefix: prefix, width: width, maxLines: maxLines)
            memo = (prefix, width, height)
            return height
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Return sends, Shift-Return breaks the line — the same bargain the SwiftUI field made,
            // which is why it is spelled out here rather than left to AppKit's default.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.onSubmit()
            return true
        }
    }

    /// `NSTextViewDelegate`'s editing callbacks fire on the first *change*, not on focus, and the
    /// composer's stroke has to follow focus. Responder transitions are the only accurate signal.
    @MainActor
    final class FocusReportingTextView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocusChange?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onFocusChange?(false) }
            return resigned
        }
    }
}
