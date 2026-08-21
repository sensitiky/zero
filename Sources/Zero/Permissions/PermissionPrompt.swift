import SwiftUI
import ZeroCore

/// The permission request, in the chat.
///
/// Not a terminal prompt and not a modal sheet: it belongs where the tool call is, because the
/// decision is about that call. The operation is shown in full — truncating it is how someone
/// approves what they did not read (FR-23).
struct PermissionPrompt: View {
    let request: PermissionRequest
    let resolve: (PermissionOption) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                Text("\(request.toolName) needs permission")
                    .font(.callout.weight(.medium))
            }
            ScrollView {
                Text(request.detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    Button(option.label) { resolve(option) }
                        .keyboardShortcut(shortcut(for: option.kind), modifiers: [])
                        .accessibilityHint(hint(for: option.kind))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Theme.foreground(scheme).opacity(0.05))
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
