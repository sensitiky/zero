import SwiftUI
import ZeroCore

/// What a session is doing, as a mark. Spoken by `SessionRow`, which owns the label.
struct StateDot: View {
    let state: SessionState
    let awaiting: Bool
    /// See `SessionRow`: the row under this dot may be filled with the foreground token, and the
    /// mark then has to be drawn in the background one.
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 7
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 14

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: dot, height: dot)
            // The ring, not the hue, is what carries "needs you", so it stays on the foreground
            // token at full weight rather than taking the accent as well: desaturate the screen and
            // the ring is still there at 16.74:1, which is the whole basis of FR-9. The accent is
            // added on top of that signal, never in place of it.
            .overlay {
                if awaiting {
                    Circle()
                        .stroke(Theme.rowForeground(scheme, selected: isSelected), lineWidth: 1)
                        .frame(width: ring, height: ring)
                }
            }
            .frame(width: slot, height: slot)
    }

    /// The accent no longer has to stand down on a selected row.
    ///
    /// It did when AppKit filled that row with the system accent blue, where violet measured about
    /// 1.2:1 and the dot read as a hole in the ring. The fill is the foreground token now
    /// (`SessionSidebar`), so the mark keeps the same two numbers it has everywhere else — 4.39:1 on
    /// `ink`, 3.82:1 on `paper` — and a session waiting on you stays marked while you are in it.
    private var fill: Color {
        awaiting ? Theme.accent : Theme.rowForeground(scheme, selected: isSelected).opacity(opacity)
    }

    private var opacity: Double {
        switch state {
        case .running, .waitingPermission: return 1
        case .idle: return 0.45
        case .finished: return 0.3
        case .error: return 0.75
        }
    }
}
