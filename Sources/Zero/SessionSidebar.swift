import SwiftUI
import ZeroCore

/// The session list. Its job is to answer "which one needs me" without being read carefully.
struct SessionSidebar: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List(selection: $model.selectedSessionID) {
            if model.sessions.isEmpty {
                Text("No sessions")
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            }
            ForEach(model.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
            }
        }
        .listStyle(.sidebar)
    }
}

struct SessionRow: View {
    let session: AppModel.SessionSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: session.state, awaiting: session.pendingPermission != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(session.branch)
                    .font(.caption)
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Spelled out for VoiceOver: a coloured dot conveys nothing without it.
    private var accessibilityLabel: String {
        let status = session.pendingPermission != nil
            ? "waiting for your permission"
            : String(describing: session.state)
        return "\(session.title), branch \(session.branch), \(status)"
    }
}

struct StateDot: View {
    let state: SessionState
    let awaiting: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(Theme.foreground(scheme).opacity(awaiting ? 1 : opacity))
            .frame(width: 7, height: 7)
            // Shape, not just colour: the palette is monochrome, so a ring is what distinguishes
            // "needs you" from "busy" for anyone who cannot rely on a brightness difference.
            .overlay {
                if awaiting {
                    Circle().stroke(Theme.foreground(scheme), lineWidth: 1).frame(width: 13, height: 13)
                }
            }
            .frame(width: 14, height: 14)
    }

    private var opacity: Double {
        switch state {
        case .running: return 1
        case .waitingPermission: return 1
        case .idle: return 0.45
        case .finished: return 0.3
        case .error: return 0.75
        }
    }
}
