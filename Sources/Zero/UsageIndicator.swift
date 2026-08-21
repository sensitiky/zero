import SwiftUI
import ZeroCore

/// Consumption as a ring in the toolbar, with the numbers a click away.
///
/// Replaces a permanent inspector column. A second sidebar spends a fifth of the window on figures
/// you glance at occasionally — the ring is the glance, and the popover is the read.
struct UsageIndicator: View {
    let usage: Usage
    private let pricing = PricingTable.bundled()
    @State private var showingDetail = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            ring
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            UsageDetail(usage: usage, pricing: pricing)
        }
    }

    private var fraction: Double? {
        pricing.contextFraction(of: usage)
    }

    @ViewBuilder
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Theme.foreground(scheme).opacity(0.18), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        Theme.foreground(scheme).opacity(fraction > 0.85 ? 1 : 0.75),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            } else {
                // No denominator, so no fraction is drawn. A full or empty ring here would be a
                // claim about a number we were never given.
                Circle()
                    .fill(Theme.foreground(scheme).opacity(0.35))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
    }

    private var helpText: String {
        guard let fraction else { return "Usage — context unknown for this model" }
        return "Context \(Int(fraction * 100))% used"
    }

    private var accessibilityLabel: String {
        guard let fraction else { return "Usage details. Context usage unknown." }
        return "Usage details. Context \(Int(fraction * 100)) percent used."
    }
}

/// The breakdown, shown on demand.
struct UsageDetail: View {
    let usage: Usage
    let pricing: PricingTable
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let model = usage.model {
                Text(model).font(.callout.weight(.medium)).monospaced()
            }

            if let fraction = pricing.contextFraction(of: usage), let tokens = usage.contextTokens {
                section("Context") {
                    row("Used", "\(tokens.formatted(.number)) · \(Int(fraction * 100))%")
                }
            }

            section("Tokens") {
                row("Input", count(usage.inputTokens))
                row("Output", count(usage.outputTokens))
                row("Cache read", count(usage.cacheReadTokens))
                row("Cache write", count(usage.cacheWriteTokens))
                row("Thinking", count(usage.thinkingTokens))
            }

            section(usage.costUSD != nil ? "Cost, reported" : "Cost, estimated") {
                row("Total", cost)
            }
        }
        .padding(16)
        .frame(width: 250)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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

    /// "unknown" rather than a zero: a zero says this was free, which is a different and wrong claim.
    private var cost: String {
        guard let value = pricing.cost(of: usage) else { return "unknown" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(4)))
    }
}
