import SwiftUI
import ZeroCore

/// The box you type into. One raised, rounded surface holding the field and its controls, rather
/// than a bare row with a button beside it — the controls sit inside because they act on what is in
/// it, and putting them outside makes the box a form field when it is the main thing on the screen.
///
/// It **owns the draft**. Both call sites previously held `@State private var draft` themselves, and
/// in `ConversationPane` that meant every keystroke invalidated the pane's `body` and rebuilt
/// `TranscriptView` with it — the problem the cache in `MarkdownText` was built to make affordable.
/// With the text living here, a keystroke invalidates this view and nothing above it.
struct Composer<Trailing: View>: View {
    let placeholder: String
    /// What the field is for, spoken. Not the placeholder: "Reply" is a hint, "Message to <session>"
    /// is what VoiceOver needs.
    let fieldLabel: String
    let usage: Usage
    /// Beyond "the field is non-empty", which this view already knows. `ComposeView` cannot start a
    /// session without a model, and neither can start one twice.
    var canSubmit: Bool = true
    /// The compose screen opens with the cursor already in the box; the reply composer does not
    /// steal focus from a conversation you are reading.
    var autofocus: Bool = false
    /// Pre-fills the field, editable before it is ever sent — the handoff sheet seeds this with the
    /// source session's transcript (010-provider-handoff). Every other call site keeps the default
    /// empty draft.
    var initialText: String = ""
    let onSubmit: (String) -> Void
    /// What sits between the usage ring and the trailing edge — the send control, or whatever
    /// replaces it. `ConversationPane` swaps in Stop while the agent is running.
    let trailing: (_ submit: @escaping () -> Void, _ enabled: Bool) -> Trailing

    @Environment(\.colorScheme) private var scheme
    /// Plain state rather than `@FocusState`: focus now comes from the text view's responder
    /// transitions, because `ComposerTextView` is an AppKit view and SwiftUI's focus system does not
    /// reach into one.
    @State private var focused = false
    @State private var draft: String

    init(
        placeholder: String,
        fieldLabel: String,
        usage: Usage,
        canSubmit: Bool = true,
        autofocus: Bool = false,
        initialText: String = "",
        onSubmit: @escaping (String) -> Void,
        @ViewBuilder trailing: @escaping (_ submit: @escaping () -> Void, _ enabled: Bool) -> Trailing
    ) {
        self.placeholder = placeholder
        self.fieldLabel = fieldLabel
        self.usage = usage
        self.canSubmit = canSubmit
        self.autofocus = autofocus
        self.initialText = initialText
        self.onSubmit = onSubmit
        self.trailing = trailing
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Not a `TextField`: a field reports a size that depends on the whole draft, and the
            // stack around it asks for that size several times per display cycle. See
            // docs/bugs/004-composer-input-lag and the note on `ComposerTextView`.
            ComposerTextView(
                text: $draft,
                maxLines: ComposerMetrics.maxLines,
                autofocus: autofocus,
                accessibilityLabel: fieldLabel,
                onSubmit: submit,
                onFocusChange: { focused = $0 }
            )
            // An `NSTextView` has no placeholder, and an overlay does not feed its size back into
            // the layout, so the cheap answer above stays cheap.
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }

            // Usage sits immediately left of the send control — the two things that live at the end
            // of every message: what it costs, and the button that sends it.
            UsageIndicator(usage: usage)

            trailing(submit, isReady)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .zeroPanel(
            scheme,
            radius: Theme.Radius.composer,
            elevation: .raised,
            stroke: focused ? Theme.Stroke.focus : Theme.Stroke.hairline
        )
        .zeroAnimation(Theme.Motion.feedback, value: focused)
    }

    private var isReady: Bool {
        canSubmit && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clearing the field is part of submitting, and it happens here so no call site can forget.
    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady else { return }
        draft = ""
        onSubmit(text)
    }
}
