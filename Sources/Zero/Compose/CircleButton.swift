import SwiftUI

/// The single round control at the end of a composer. Filled, because it is the one action there.
///
/// One component rather than the two identical `circleButton` helpers that `ConversationPane` and
/// `ComposeView` each carried: they were already annotated as having to match each other, which is
/// a comment doing a type's job.
struct CircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    /// The control and the glyph in it both grow with the text size: a send button that stays 26pt
    /// next to body text set at the largest Dynamic Type size is a button you can no longer hit.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 12

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(Theme.background(scheme))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Theme.foreground(scheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
