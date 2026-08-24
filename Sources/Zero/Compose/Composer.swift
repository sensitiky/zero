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
    let onSubmit: (String) -> Void
    /// What sits between the usage ring and the trailing edge — the send control, or whatever
    /// replaces it. `ConversationPane` swaps in Stop while the agent is running.
    @ViewBuilder let trailing: (_ submit: @escaping () -> Void, _ enabled: Bool) -> Trailing

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .focused($focused)
                .accessibilityLabel(fieldLabel)
                .onSubmit(submit)

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
        .onAppear { if autofocus { focused = true } }
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
