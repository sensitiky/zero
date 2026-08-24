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
                    ToolStatusMark(status: call.status)
                    Text(call.name).font(Theme.code(weight: .medium))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary(scheme))
                    if let duration {
                        Text(duration)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary(scheme))
                    }
                }
            }
        }
        .padding(10)
        .zeroPanel(scheme, radius: Theme.Radius.inline, elevation: .raised)
        .accessibilityLabel("Tool \(call.name), \(statusText)")
    }

    /// What the call is doing, said rather than named. The enum case is a state in a protocol; this
    /// is the line a person reads next to a file path.
    private var statusText: String {
        switch call.status {
        case .pending: "waiting to run"
        case .running: "running"
        case .succeeded: "done"
        case .denied: "you denied this"
        case .failed(let reason): reason.isEmpty ? "failed" : "failed — \(reason)"
        }
    }

    /// How long it took, at the precision a person can act on.
    ///
    /// Raw milliseconds are the machine's unit: "1483 ms" makes you divide before you know whether
    /// to care. Anything under a tenth of a second is not worth a number at all, so it does not get
    /// one.
    private var duration: String? {
        guard let started = call.startedAt, let ended = call.endedAt else { return nil }
        let seconds = ended.timeIntervalSince(started)
        switch seconds {
        case ..<0.1: return "instant"
        case ..<10: return String(format: "%.1fs", seconds)
        case ..<60: return "\(Int(seconds.rounded()))s"
        default:
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds.rounded()) % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
    }

    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text(body)
                .font(Theme.code())
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
    /// Computed once per edit and held, never worked out in `body`. The precedent, and the reason,
    /// is in the header of `MarkdownText.swift`: a transcript re-renders far more often than its
    /// contents change, and an edit that arrives once should not be diffed on every pass.
    @State private var diff: FileDiff?
    @State private var revealed = false
    /// The line-number gutter is a column of digits, so it scales with them or the numbers clip.
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(edit.path)
                .font(Theme.code(.caption))
                .foregroundStyle(Theme.secondary(scheme))
                .textSelection(.enabled)
            if let diff {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { index, hunk in
                        // Between hunks, say what was skipped rather than silently joining two
                        // stretches of a file that are nowhere near each other.
                        if index > 0 {
                            gap(before: hunk)
                        }
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { offset, line in
                            row(line, showOldNumbers: diff.shape == .comparison)
                                .opacity(revealed ? 1 : 0)
                                .zeroAnimation(
                                    // Staggered across one fixed window rather than a fixed delay
                                    // per line: what this shows is *what* arrived, and a forty-line
                                    // diff must not take forty steps to say it (FR-20.4).
                                    Theme.Motion.arrival.delay(
                                        Theme.Motion.stagger * Double(offset) / Double(max(hunk.lines.count, 1))
                                    ),
                                    value: revealed
                                )
                        }
                    }
                }
                .zeroPanel(scheme, radius: Theme.Radius.inline, elevation: .raised)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(summary(of: diff))
            }
        }
        .task(id: edit) {
            diff = FileDiff(edit: edit)
            revealed = true
        }
    }

    /// What a reader sees at a glance and a screen reader otherwise would not: how big the change
    /// is, before stepping through it line by line.
    private func summary(of diff: FileDiff) -> String {
        guard diff.shape == .comparison else {
            let count = diff.hunks.first?.lines.count ?? 0
            return "\(edit.path), written: \(count) lines"
        }
        let added = diff.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
        let removed = diff.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
        return "Diff of \(edit.path): \(added) lines added, \(removed) removed, in \(diff.hunks.count) sections"
    }

    private func row(_ line: FileDiff.Line, showOldNumbers: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showOldNumbers {
                number(line.oldLine)
            }
            number(line.newLine)
            Text(marker(for: line.kind))
                .font(Theme.code())
                .foregroundStyle(Theme.secondary(scheme))
            Text(line.text)
                .font(Theme.code())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Monochrome palette, so removed and added lines are told apart by their marker and by a
        // tint of the single foreground colour, not by red and green.
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Theme.foreground(scheme).opacity(tint(for: line.kind)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(line))
    }

    /// The line number on one side, or a blank of the same width when the line does not exist there
    /// — so the two gutters stay columns rather than collapsing on every changed line.
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(Theme.code(.caption))
            .foregroundStyle(Theme.secondary(scheme))
            .monospacedDigit()
            .frame(width: gutter, alignment: .trailing)
            .textSelection(.disabled)
    }

    private func gap(before hunk: FileDiff.Hunk) -> some View {
        HStack(spacing: 6) {
            Text("⋯")
                .font(Theme.code(.caption))
                .frame(width: gutter, alignment: .trailing)
            Text("continues at line \(hunk.newStart)")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.secondary(scheme))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // One element, not an ellipsis followed by a sentence: "⋯" read aloud is noise.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unchanged lines skipped. Continues at line \(hunk.newStart).")
    }

    private func marker(for kind: FileDiff.Line.Kind) -> String {
        switch kind {
        case .removed: "−"
        case .added: "+"
        case .context: " "
        }
    }

    private func tint(for kind: FileDiff.Line.Kind) -> Double {
        switch kind {
        case .removed: Theme.Diff.removed
        case .added: Theme.Diff.added
        case .context: 0
        }
    }

    /// A marker and a tint convey nothing to a screen reader, so each line says what it is.
    private func spoken(_ line: FileDiff.Line) -> String {
        switch line.kind {
        case .removed: "Removed line \(line.oldLine ?? 0): \(line.text)"
        case .added: "Added line \(line.newLine ?? 0): \(line.text)"
        case .context: "Line \(line.newLine ?? 0): \(line.text)"
        }
    }
}

/// Where a tool call is, as a shape that changes rather than a word that gets replaced.
///
/// FR-20.2: pending, running and done are three states of one mark, so the transition between them
/// is something you see happen. The word beside it stays — it is what a screen reader reads and what
/// spells out a failure — but the movement is carried by the shape.
struct ToolStatusMark: View {
    let status: ToolCall.Status
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.foreground(scheme).opacity(Theme.Stroke.control), lineWidth: 1.5)
            // The same circle at three sizes: empty when queued, half when working, full when done.
            // One shape growing, not three different glyphs swapped in and out.
            Circle()
                .fill(Theme.foreground(scheme).opacity(weight))
                .scaleEffect(scale)
        }
        .frame(width: size, height: size)
        .zeroAnimation(Theme.Motion.value, value: scale)
        .accessibilityHidden(true)
    }

    private var scale: CGFloat {
        switch status {
        case .pending: 0
        case .running: 0.55
        case .succeeded, .failed, .denied: 1
        }
    }

    /// A call that did not succeed is drawn as an outline that never filled in, so "finished" and
    /// "finished badly" are not the same mark.
    private var weight: Double {
        switch status {
        case .pending, .running, .succeeded: 1
        case .failed, .denied: Theme.Mark.unknown
        }
    }
}
