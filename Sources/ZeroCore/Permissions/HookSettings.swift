import Foundation

/// Builds the `--settings` JSON that installs Zero's permission hook for one session.
///
/// Passed inline on the command line rather than written to a file: Zero must never edit the
/// user's own `settings.json`, and an inline blob also disappears when the session does.
public enum HookSettings {
    /// Tools worth stopping for. `matcher` is a regex over the tool name.
    ///
    /// Read-only tools are deliberately absent: prompting for every file read trains the user to
    /// approve without looking, which costs more safety than it buys.
    public static let defaultMatcher = "Bash|Write|Edit|NotebookEdit|WebFetch"

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
