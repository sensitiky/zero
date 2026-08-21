import SwiftUI
import ZeroCore

/// Tokens, cost, and what the session is attached to.
struct InspectorPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let session = model.selectedSession {
                    group("Session") {
                        row("Provider", session.provider)
                        row("Model", session.model)
                        row("Branch", session.branch)
                        row("State", String(describing: session.state))
                    }
                    group("Tokens") {
                        row("Input", count(session.usage.inputTokens))
                        row("Output", count(session.usage.outputTokens))
                        row("Cache read", count(session.usage.cacheReadTokens))
                        row("Cache write", count(session.usage.cacheWriteTokens))
                        row("Thinking", count(session.usage.thinkingTokens))
                    }
                    group("Cost") {
                        row("Reported", cost(session.usage.costUSD))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .zeroSurface(scheme)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func count(_ value: Int?) -> String {
        value.map { $0.formatted(.number) } ?? "—"
    }

    /// "unknown" rather than a zero, because FR-30 forbids implying a cost we were never told.
    private func cost(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(4)))
    }
}
