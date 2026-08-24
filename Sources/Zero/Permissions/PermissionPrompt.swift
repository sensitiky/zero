import SwiftUI
import ZeroCore

/// The permission request, in the chat.
///
/// A card in the same family as a tool call cell — rounded, floating over the conversation rather
/// than a flat highlighted bar. The operation is shown in full: truncating it is how someone
/// approves what they did not read (FR-23).
///
/// This is one of the two surfaces allowed to carry `Theme.accent`, and it carries it as a border
/// rather than a fill: the card is already the only floating thing on screen and already has a
/// shape of its own, so the hue reinforces "this is waiting on you" without becoming the only thing
/// saying it.
struct PermissionPrompt: View {
    let request: PermissionRequest
    let resolve: (PermissionOption) -> Void
    @Environment(\.colorScheme) private var scheme
    /// How much of the operation is visible before it scrolls. In lines, effectively — so it grows
    /// with the text rather than showing fewer and fewer of them.
    @ScaledMetric(relativeTo: .callout) private var detailHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised")
                    .font(.callout)
                Text(request.toolName).font(Theme.code(weight: .medium))
                Text("wants to run this")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary(scheme))
                Spacer(minLength: 0)
            }

            ScrollView {
                Text(request.detail)
                    .font(Theme.code())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: detailHeight)
            .zeroPanel(scheme, radius: Theme.Radius.content, elevation: .sunken, stroke: nil)

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
        .zeroPanel(scheme, radius: Theme.Radius.card, elevation: .floating, stroke: nil)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1)
        }
        .padding(.horizontal, 20)
        .zeroMeasure()
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
                            : Theme.foreground(scheme).opacity(hovering ? Theme.Fill.hover : 0)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        Theme.foreground(scheme).opacity(isPrimary ? 0 : Theme.Stroke.control),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .zeroAnimation(Theme.Motion.feedback, value: hovering)
    }

    /// The single-approval path is the one filled control; both denials and "always" stay outlined
    /// so nothing but the ordinary allow reads as the default action.
    private var isPrimary: Bool { option.kind == .allowOnce }
}
