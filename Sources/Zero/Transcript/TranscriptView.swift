import SwiftUI
import ZeroCore

/// The transcript.
///
/// A list of typed entries, not a text view: a tool call, a diff and a plan are different things to
/// look at, and flattening them into a stream of characters is exactly what embedding a terminal
/// does. Everything here stays selectable and searchable (FR-26).
struct TranscriptView: View {
    let entries: [Transcript.Entry]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing is applied per row from what precedes it, so the stack itself adds none.
                // A conversation does not have one gap: the reply to a question sits closer to it
                // than the next question does to the reply.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        view(for: row)
                            .id(row.id)
                            .padding(.top, index == 0 ? 0 : gap(after: rows[index - 1], before: row))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                // A measure, not the window width. Text running the full width of a wide display is
                // hard to read, and it is most of what makes a chat feel like a log file.
                .zeroMeasure()
            }
            .onChange(of: entries.last?.id) { _, newValue in
                guard let newValue else { return }
                // Jumps rather than glides under reduced motion: the transcript still follows the
                // conversation, it just stops sliding to do it.
                withAnimation(reduceMotion ? nil : Theme.Motion.scroll) {  // design-token-lint:allow — reads reduceMotion itself
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Rows

    /// What actually gets drawn: mostly entries one to one, except that a run of back-to-back tool
    /// calls becomes a single row. Eight consecutive reads are one action the agent took, and eight
    /// boxes is the transcript telling you they were eight things to read.
    private enum Row: Identifiable {
        case entry(Transcript.Entry)
        case toolRun([ToolCall], id: UUID)

        var id: UUID {
            switch self {
            case .entry(let entry): entry.id
            case .toolRun(_, let id): id
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        var run: [ToolCall] = []
        var runID: UUID?

        func flush() {
            guard let id = runID else { return }
            // A run of one is just a tool call. Wrapping it would add a disclosure you have to open
            // to reach a disclosure you have to open.
            result.append(run.count == 1 ? .entry(.tool(id: id, call: run[0])) : .toolRun(run, id: id))
            run = []
            runID = nil
        }

        for entry in entries {
            if case .tool(let id, let call) = entry {
                if runID == nil { runID = id }
                run.append(call)
            } else {
                flush()
                result.append(.entry(entry))
            }
        }
        flush()
        return result
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case .entry(let entry): self.row(for: entry)
        case .toolRun(let calls, _): ToolRunCell(calls: calls)
        }
    }

    // MARK: - Rhythm

    /// The gap between two rows, from what they are rather than from one constant.
    ///
    /// Three distances, and each one says something: a turn boundary is a paragraph break, a
    /// continuation is a line break, and work the agent did on its own sits tight against the text
    /// that introduced it.
    private func gap(after previous: Row, before next: Row) -> CGFloat {
        switch (kind(of: previous), kind(of: next)) {
        // A new turn starting. The biggest break in the transcript.
        case (_, .user), (.user, _):
            26
        // The agent's own working: tool calls, plans and thinking belong to the text above them.
        case (.assistant, .work), (.work, .work), (.work, .assistant):
            8
        default:
            18
        }
    }

    private enum RowKind { case user, assistant, work }

    private func kind(of row: Row) -> RowKind {
        switch row {
        case .toolRun: .work
        case .entry(let entry):
            switch entry {
            case .userText: .user
            case .assistantText, .notice: .assistant
            case .thinking, .tool, .plan: .work
            }
        }
    }

    @ViewBuilder
    private func row(for entry: Transcript.Entry) -> some View {
        switch entry {
        case .userText(_, let text):
            UserMessage(text: text)
        case .assistantText(_, let text):
            MarkdownBody(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(_, let text):
            ThinkingBlock(text: text)
        case .tool(_, let call):
            ToolCallCell(call: call)
        case .plan(_, let items):
            PlanList(items: items)
        case .notice(_, let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.secondary(scheme))
                .textSelection(.enabled)
        }
    }
}

/// Reasoning, collapsed by default: it is context for when the answer surprises you, not the answer.
struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            MarkdownBody(text: text)
                .font(.callout)
                .foregroundStyle(Theme.secondary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text("Thinking")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary(scheme))
        }
    }
}

struct PlanList: View {
    let items: [PlanItem]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Plan")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary(scheme))
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: item.status)).monospaced()
                    Text(item.title).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title), \(item.status.rawValue)")
            }
        }
    }

    /// Glyphs rather than colour: the palette is monochrome by design.
    private func marker(for status: PlanItem.Status) -> String {
        switch status {
        case .pending: return "○"
        case .inProgress: return "◐"
        case .completed: return "●"
        }
    }
}

/// What the user said.
///
/// Indented and boxed rather than tinted: the palette is monochrome, so position and enclosure are
/// what separate the two voices — and they keep working for anyone who cannot tell two greys apart.
struct UserMessage: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            MarkdownBody(text: text)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .zeroPanel(scheme, radius: Theme.Radius.content, elevation: .raised, stroke: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(text)")
    }
}
