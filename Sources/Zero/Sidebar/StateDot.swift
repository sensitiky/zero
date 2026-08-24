import SwiftUI
import ZeroCore

/// What a session is doing, as a mark. Spoken by `SessionRow`, which owns the label.
struct StateDot: View {
    let state: SessionState
    let awaiting: Bool
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 7
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 14

    var body: some View {
        Circle()
            .fill(awaiting ? Theme.accent : Theme.foreground(scheme).opacity(opacity))
            .frame(width: dot, height: dot)
            // The ring, not the hue, is what carries "needs you", so it stays on the foreground
            // token at full weight rather than taking the accent as well: desaturate the screen and
            // the ring is still there at 16.74:1, which is the whole basis of FR-9. The accent is
            // added on top of that signal, never in place of it.
            .overlay {
                if awaiting {
                    Circle()
                        .stroke(Theme.foreground(scheme), lineWidth: 1)
                        .frame(width: ring, height: ring)
                }
            }
            .frame(width: slot, height: slot)
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
