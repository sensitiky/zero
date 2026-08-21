import Foundation

/// Decides which tool calls are routine enough to auto-approve, and which stay critical enough to
/// ask a human — the lever that makes `PermissionOrigin.rule(_:)` usable without asking for
/// permission on every single tool call.
///
/// This is deliberately conservative in one direction only: it is fine to over-classify something
/// as `.sensitive` (worst case, one extra click), but a false `.routine` skips the human entirely.
/// When parsing fails or a shape is unrecognized, the answer is always `.sensitive` — see each
/// `classify` branch's `guard`.
public enum CommandRiskClassifier {
    public enum Risk: Sendable, Equatable {
        case routine
        case sensitive(reason: String)
    }

    /// `toolInputJSON` is the pretty-printed JSON the hook forwards as `PermissionRequest.detail`.
    public static func classify(toolName: String, toolInputJSON: String) -> Risk {
        switch toolName {
        case "WebFetch", "WebSearch":
            // Named explicitly by the product owner as a case that must keep asking: outbound
            // network requests can exfiltrate whatever the agent has read.
            return .sensitive(reason: "fetches a URL")

        case "Bash":
            return classifyBash(toolInputJSON)

        case "Write", "Edit", "NotebookEdit":
            return classifyFileWrite(toolInputJSON)

        default:
            // An unrecognized tool is exactly the case a hardcoded allowlist would get wrong
            // silently. Ask, rather than guess.
            return .sensitive(reason: "unrecognized tool")
        }
    }

    // MARK: - Bash

    /// Substrings checked against the lowercased command. Substring rather than a full shell
    /// parser: a false positive costs one extra click, a false negative skips a human entirely, so
    /// this errs toward catching more than a precise parser would.
    private static let destructivePatterns: [(pattern: String, reason: String)] = [
        ("drop table", "drops a database table"),
        ("drop database", "drops a database"),
        ("drop schema", "drops a database schema"),
        ("truncate table", "truncates a database table"),
        ("delete from", "deletes database rows"),
        ("rm -rf", "recursively force-deletes files"),
        ("rm -fr", "recursively force-deletes files"),
        ("mkfs", "formats a filesystem"),
        ("dd if=", "writes raw disk blocks"),
        ("chmod -r 777", "makes files world-writable recursively"),
        ("chown -r", "recursively changes file ownership"),
        (":(){ :|:& };:", "is a fork bomb"),
        ("sudo ", "runs as another user"),
        ("su -", "switches user"),
        ("doas ", "runs as another user"),
        ("curl ", "fetches from the network"),
        ("wget ", "fetches from the network"),
        ("http --", "fetches from the network"),
        ("nc -", "opens a raw network connection"),
        ("git push --force", "force-pushes, which can discard remote history"),
        ("git push -f", "force-pushes, which can discard remote history"),
        ("git reset --hard", "discards uncommitted work"),
        ("git clean -fd", "deletes untracked files"),
    ]

    /// Path fragments that mean "this command touches credentials," regardless of which verb runs.
    private static let secretPathFragments = [
        ".ssh/", ".aws/credentials", ".npmrc", ".netrc", "id_rsa", ".pem", ".env",
    ]

    private static func classifyBash(_ toolInputJSON: String) -> Risk {
        guard let command = jsonField(toolInputJSON, "command")?.lowercased() else {
            return .sensitive(reason: "could not read the command")
        }
        for (pattern, reason) in destructivePatterns where command.contains(pattern) {
            return .sensitive(reason: reason)
        }
        for fragment in secretPathFragments where command.contains(fragment) {
            return .sensitive(reason: "touches credentials")
        }
        return .routine
    }

    // MARK: - Write / Edit / NotebookEdit

    private static func classifyFileWrite(_ toolInputJSON: String) -> Risk {
        guard let path = jsonField(toolInputJSON, "file_path")?.lowercased() else {
            return .sensitive(reason: "could not read the file path")
        }
        for fragment in secretPathFragments where path.contains(fragment) {
            return .sensitive(reason: "writes to a credentials file")
        }
        return .routine
    }

    // MARK: - Minimal JSON field read

    /// Reads one top-level string field without a full model — the tool input shapes here are
    /// simple and flat, and a `Codable` type per tool would be more code than the problem needs.
    private static func jsonField(_ json: String, _ key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
