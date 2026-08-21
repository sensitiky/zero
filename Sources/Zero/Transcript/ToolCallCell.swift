import SwiftUI
import ZeroCore

/// One tool call, collapsed to a line until you want the detail.
struct ToolCallCell: View {
    let call: ToolCall
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let edit = call.edit {
                        DiffView(edit: edit)
                    } else if let input = call.input {
                        labelled("Input", input)
                    }
                    if let output = call.output, !output.isEmpty {
                        labelled("Output", output)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {
                    Text(call.name).font(.callout.weight(.medium)).monospaced()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                    if let duration {
                        Text(duration)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                    }
                }
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.foreground(scheme).opacity(0.18), lineWidth: 1)
        )
        .accessibilityLabel("Tool \(call.name), \(statusText)")
    }

    private var statusText: String {
        switch call.status {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "done"
        case .denied: return "denied"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    private var duration: String? {
        guard let started = call.startedAt, let ended = call.endedAt else { return nil }
        return "\(Int(ended.timeIntervalSince(started) * 1000)) ms"
    }

    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            Text(body)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A file edit rendered as a diff (FR-20).
///
/// The reason the product exists in this shape: a diff shown as raw JSON is a diff you have to
/// decode by hand.
struct DiffView: View {
    let edit: FileEdit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(edit.path)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.marker)
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                        Text(line.text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Monochrome palette, so removed and added lines are told apart by marker and
                    // by a background tint of the single foreground colour, not by red and green.
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.foreground(scheme).opacity(line.tint))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.foreground(scheme).opacity(0.15), lineWidth: 1)
            )
        }
    }

    private struct Line {
        let marker: String
        let text: String
        let tint: Double
    }

    /// A whole-block diff: `Write` reports no previous text, so there is nothing to compare against
    /// and pretending otherwise would invent a diff.
    private var lines: [Line] {
        var result: [Line] = []
        if let old = edit.oldText, !old.isEmpty {
            result += old.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(marker: "−", text: String($0), tint: 0.10) }
        }
        if let new = edit.newText, !new.isEmpty {
            result += new.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(marker: "+", text: String($0), tint: 0.04) }
        }
        return result
    }
}
