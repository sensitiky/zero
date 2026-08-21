import Foundation

/// Builds the `--settings` JSON that installs the PreToolUse hook in Claude Code.
///
/// Claude Code accepts a JSON settings dict via `--settings '<json>'`. The hook is configured
/// as a `PreToolUse` entry with the helper binary path.
public struct HookSettings: Sendable {
    /// The path to the zero-permission-hook binary.
    private let helperPath: String

    public init(helperPath: String) {
        self.helperPath = helperPath
    }

    /// Generates the JSON string to pass to Claude Code's `--settings` flag.
    ///
    /// The format is: `{"hooks": {"PreToolUse": {"command": "..."}}}`
    public func settingsJSON() throws -> String {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    "command": helperPath
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw SettingsError.encodingFailed
        }
        return json
    }

    enum SettingsError: Error, Sendable {
        case encodingFailed
    }
}
