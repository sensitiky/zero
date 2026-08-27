import SwiftUI

/// Offered the moment a turn ends because the provider ran out of context — the one signal this
/// app treats differently from an ordinary reply (010-provider-handoff, FR-3).
///
/// Same card family as `PermissionPrompt` — floating over the conversation, not a flat bar — but
/// carries none of the app's one accent hue: that color is reserved for the two surfaces
/// `Scripts/lint-design-tokens.sh` already allows it in, and an accent-ringed variant of this card
/// is its own, separate ticket (resolved open question, see the PRD).
struct ContextExhaustedCard: View {
    let continueAction: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.up.right")
                .font(.callout)
                .foregroundStyle(Theme.secondary(scheme))
            Text("This provider ran out of context.")
                .font(.callout)
            Spacer(minLength: 0)
            Button("Continue with another provider", action: continueAction)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .zeroPanel(scheme, radius: Theme.Radius.card, elevation: .floating, stroke: nil)
        .padding(.horizontal, 20)
        .zeroMeasure()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "This provider ran out of context. Continue with another provider, or dismiss."
        )
    }
}
