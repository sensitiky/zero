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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(entries) { entry in
                        row(for: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                // A measure, not the window width. Text running the full width of a wide display is
                // hard to read, and it is most of what makes a chat feel like a log file.
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: entries.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: Transcript.Entry) -> some View {
        switch entry {
        case .userText(_, let text):
            UserMessage(text: text)
        case .assistantText(_, let text):
            Text(text)
                .textSelection(.enabled)
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
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
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
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text("Thinking")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
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
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
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
            Text(text)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.foreground(scheme).opacity(0.08))
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(text)")
    }
}
