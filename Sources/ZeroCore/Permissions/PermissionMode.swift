import Foundation

/// How a session decides tool-call permissions, chosen by the user, never by decoded output.
///
/// Three states, not a spectrum: `ask` shows Zero's native control for every gated tool call,
/// `auto` delegates routine tools to the provider's own judgment where one is verified to exist
/// (Claude Code's `--permission-mode auto`) and otherwise resolves them locally without a
/// classifier of Zero's own (see FR-36 in `001-agent-chat-core`, retired for exactly that reason),
/// and `bypass` never prompts at all. Per-tool granularity is a non-goal (003-permission-modes).
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case ask
    case auto
    case bypass

    /// The default for a session with no mode read yet — the most restrictive, per FR-24.
    public static let `default` = PermissionMode.ask

    public var label: String {
        switch self {
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }

    /// Parses a persisted value, falling back to the safe default rather than trusting a corrupt
    /// or unrecognized string. A permission mode that fails open on a bad read is the exact bug
    /// `PermissionBroker` already refuses to have — this is that same principle for the mode itself.
    public init(persisted: String?) {
        self = persisted.flatMap(PermissionMode.init(rawValue:)) ?? .default
    }
}
