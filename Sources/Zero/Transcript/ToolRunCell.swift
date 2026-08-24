import SwiftUI
import ZeroCore

/// A run of back-to-back tool calls, as one row.
///
/// Eight consecutive reads are one thing the agent did, and eight separate boxes is the transcript
/// insisting they were eight things for you to read. Collapsed it is a line; expanded it is exactly
/// what each call showed before, in order.
struct ToolRunCell: View {
    let calls: [ToolCall]
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.transcriptSearch) private var search

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(calls) { call in
                    ToolCallCell(call: call)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(summary).font(.callout.weight(.medium))
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary(scheme))
                }
            }
        }
        .padding(10)
        .zeroPanel(scheme, radius: Theme.Radius.inline, elevation: .raised)
        .accessibilityElement(children: expanded ? .contain : .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(expanded ? "Collapses the run" : "Expands \(calls.count) tool calls")
        // FR-26 of 001 says the whole transcript is searchable, and collapsing a run would quietly
        // carve an exception into that. When the search matches inside, the run opens itself.
        .onChange(of: matchesSearch, initial: true) { _, matches in
            if matches { expanded = true }
        }
    }

    /// "4 × Read" when the run is one tool repeated, which is the common case and the one worth
    /// naming; otherwise the count, because listing six different tool names is not a summary.
    private var summary: String {
        let names = Set(calls.map(\.name))
        if let only = names.first, names.count == 1 {
            return "\(calls.count) × \(only)"
        }
        return "\(calls.count) tool calls"
    }

    /// Only what the collapsed line cannot show: something in the run is still going, or something
    /// in it did not succeed.
    private var trailing: String? {
        let unfinished = calls.filter { $0.status == .pending || $0.status == .running }.count
        if unfinished > 0 { return unfinished == calls.count ? "running" : "\(unfinished) still running" }
        let failed = calls.filter { call in
            if case .succeeded = call.status { return false }
            return true
        }.count
        return failed > 0 ? "\(failed) did not succeed" : nil
    }

    private var spokenLabel: String {
        let names = Set(calls.map(\.name)).sorted().joined(separator: ", ")
        return "Run of \(calls.count) tool calls: \(names). \(trailing ?? "all done")."
    }

    private var matchesSearch: Bool {
        guard !search.isEmpty else { return false }
        let needle = search.lowercased()
        return calls.contains { call in
            [call.name, call.input, call.output, call.edit?.path]
                .compactMap { $0 }
                .contains { $0.lowercased().contains(needle) }
        }
    }
}

/// What is being searched for inside the transcript, if anything.
///
/// Nothing sets this yet: the only search in the app filters sessions in the sidebar, and
/// `AppModel` is explicit that searching a transcript is a different feature with a different UI.
/// It exists because `ToolRunCell` collapses content that used to be on screen, and the rule that a
/// collapsed run must open itself for a match is worth having in place before the search that will
/// need it, rather than discovered as a regression afterwards.
private struct TranscriptSearchKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var transcriptSearch: String {
        get { self[TranscriptSearchKey.self] }
        set { self[TranscriptSearchKey.self] = newValue }
    }
}
