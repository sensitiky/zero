import SwiftUI
import ZeroCore

/// Three pills — Ask / Auto / Bypass — the same fill-means-selected, outline-means-the-rest
/// language `PermissionPrompt`'s buttons already use. Always shows all three names rather than
/// hiding behind a `Menu`: this is a decision made as often as the provider is (003-permission-modes).
struct PermissionModeControl: View {
    let mode: PermissionMode
    let onSelect: (PermissionMode) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PermissionMode.allCases, id: \.self) { candidate in
                pill(for: candidate)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission mode")
    }

    private func pill(for candidate: PermissionMode) -> some View {
        let selected = candidate == mode
        return Button {
            onSelect(candidate)
        } label: {
            Text(candidate.label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(
                    selected
                        ? Theme.background(scheme)
                        : Theme.foreground(scheme).opacity(Theme.secondaryOpacity)
                )
                .background(Capsule().fill(selected ? Theme.foreground(scheme) : Color.clear))
                .overlay(
                    Capsule().stroke(Theme.foreground(scheme).opacity(selected ? 0 : 0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.label) permission mode")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Bypass never looks like Ask: an inline line, not a modal, so it stays visible for as long as
/// the mode is active without blocking keyboard operation (FR-27, 001-agent-chat-core). Text only —
/// this palette has no danger color, and one is not invented for a single state.
struct BypassWarning: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("Bypass: nothing asks permission here, including web access.")
            .font(.caption)
            .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
            .accessibilityLabel("Warning: Bypass mode never asks permission, including for web access")
    }
}
