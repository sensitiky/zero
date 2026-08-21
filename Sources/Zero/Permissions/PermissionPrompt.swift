import SwiftUI
import ZeroCore

/// The permission request, in the chat.
///
/// A card in the same family as a tool call cell — rounded, stroked, no fill of accent color —
/// rather than a flat highlighted bar. The operation is shown in full: truncating it is how someone
/// approves what they did not read (FR-23).
struct PermissionPrompt: View {
    let request: PermissionRequest
    let resolve: (PermissionOption) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised")
                    .font(.callout)
                Text(request.toolName).font(.callout.weight(.medium)).monospaced()
                Text("wants to run this")
                    .font(.callout)
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                Spacer(minLength: 0)
            }

            ScrollView {
                Text(request.detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.foreground(scheme).opacity(0.04))
            )

            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    PermissionButton(option: option) { resolve(option) }
                        .keyboardShortcut(shortcut(for: option.kind), modifiers: [])
                        .accessibilityHint(hint(for: option.kind))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.foreground(scheme).opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.foreground(scheme).opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        // Keyboard-first (FR-27): a permission prompt you can only answer with the mouse is a
        // permission prompt that gets answered carelessly.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request for \(request.toolName)")
    }

    private func shortcut(for kind: PermissionOption.Kind) -> KeyEquivalent {
        switch kind {
        case .allowOnce: return "a"
        case .allowAlways: return "A"
        case .denyOnce: return "d"
        case .denyAlways: return "D"
        }
    }

    private func hint(for kind: PermissionOption.Kind) -> String {
        switch kind {
        case .allowOnce: return "Allows this one call"
        case .allowAlways: return "Allows every call like this, from now on"
        case .denyOnce: return "Denies this one call"
        case .denyAlways: return "Denies every call like this, from now on"
        }
    }
}

/// A flat monochrome pill, filled for the one recommended action and outlined for the rest — the
/// same fill-means-primary language as the composer's send control. No color coding: the palette is
/// monochrome, so weight and fill carry what a red/green pair usually would.
private struct PermissionButton: View {
    let option: PermissionOption
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(option.label)
                .font(.callout.weight(isPrimary ? .semibold : .regular))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .foregroundStyle(isPrimary ? Theme.background(scheme) : Theme.foreground(scheme))
                .background(
                    Capsule().fill(
                        isPrimary
                            ? Theme.foreground(scheme)
                            : Theme.foreground(scheme).opacity(hovering ? 0.10 : 0.0)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        Theme.foreground(scheme).opacity(isPrimary ? 0 : 0.22),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    /// The single-approval path is the one filled control; both denials and "always" stay outlined
    /// so nothing but the ordinary allow reads as the default action.
    private var isPrimary: Bool { option.kind == .allowOnce }
}
