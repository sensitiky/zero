import SwiftUI
import ZeroCore

/// One session: what it is called, and under it what it is doing.
struct SessionRow: View {
    let session: AppModel.SessionSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: session.state, awaiting: session.pendingPermission != nil)
            VStack(alignment: .leading, spacing: 1) {
                MarkdownText(text: session.title).lineLimit(1)
                if !session.summary.isEmpty {
                    // Dimmer, and never dimmer than 70%: below that it stops clearing WCAG AAA.
                    MarkdownText(text: session.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary(scheme))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Spelled out for VoiceOver: a dot conveys nothing without it.
    private var accessibilityLabel: String {
        let status = session.pendingPermission != nil
            ? "waiting for your permission"
            : String(describing: session.state)
        return "\(session.title). \(session.summary). \(status)"
    }
}
