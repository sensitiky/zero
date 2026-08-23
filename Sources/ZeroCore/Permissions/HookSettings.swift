import Foundation

/// Builds the `--settings` JSON that installs Zero's permission hook for one session.
///
/// Passed inline on the command line rather than written to a file: Zero must never edit the
/// user's own `settings.json`, and an inline blob also disappears when the session does.
public enum HookSettings {
    /// Tools worth stopping for in `.ask` mode. `matcher` is a regex over the tool name.
    ///
    /// Read-only tools are deliberately absent: prompting for every file read trains the user to
    /// approve without looking, which costs more safety than it buys. `WebSearch` belongs beside
    /// `WebFetch` for the same exfiltration-vector reason (001-agent-chat-core, FR-24) — it was
    /// missing here until 003-permission-modes caught the gap between that decision and this code.
    public static let askMatcher = "Bash|Write|Edit|NotebookEdit|WebFetch|WebSearch"

    /// Tools worth stopping for in `.auto` mode: only the network-capable ones. `Bash`/`Write`/
    /// `Edit`/`NotebookEdit` are deliberately absent — they are exactly what `.auto` hands to the
    /// provider's own `--permission-mode auto` judgment instead of gating here.
    public static let autoMatcher = "WebFetch|WebSearch"

    /// Kept for source compatibility with existing callers; equivalent to `askMatcher`.
    public static let defaultMatcher = askMatcher

    public static func json(
        helperPath: String,
        socketPath: String,
        matcher: String = defaultMatcher
    ) -> String {
        // Both paths are quoted because the hook command is interpreted by a shell and an
        // Application Support path routinely contains spaces.
        let command = "\(shellQuoted(helperPath)) \(shellQuoted(socketPath))"
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": matcher,
                        "hooks": [["type": "command", "command": command]],
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
