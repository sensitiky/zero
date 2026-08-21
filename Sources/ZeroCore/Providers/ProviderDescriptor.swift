import Foundation

/// Describes a provider: its identity, how to find its executable, and how to invoke it.
public struct ProviderDescriptor: Sendable {
    /// Unique provider identifier: `claude`, `codex`, or a user-configured ACP slug.
    public let id: String

    /// Human-readable name shown in the UI.
    public let displayName: String

    /// Candidates to probe for the executable, in order: absolute paths or relative to candidate
    /// directories. Examples: `"claude"`, `"/opt/homebrew/bin/claude"`, `"codex"`.
    public let executableCandidates: [String]

    /// Command to invoke to get the provider's version. Yields one line of output; the registry
    /// parses it as `major.minor.patch` and compares against `minimumVersion`.
    /// Example: `["--version"]` for `claude --version` → "2.1.237".
    public let versionCommand: [String]

    /// Minimum version required to be usable. Format: `"major.minor.patch"`.
    public let minimumVersion: String

    /// Command-line arguments to pass when launching the agent for a new session.
    /// The registry appends no arguments of its own — this is the complete list.
    public let launchArguments: [String]

    /// Whether this provider requires authentication (e.g., an API key or login). Determines
    /// whether to check authentication status in addition to executable and version.
    public let requiresAuthentication: Bool

    /// Models offered in the picker.
    ///
    /// Only listed where the ids are known first-hand — Claude Code's come from captured traffic.
    /// An empty list means the picker falls back to a free-text field rather than offering names
    /// that were guessed: a menu of plausible-looking wrong ids is worse than typing the right one.
    public let knownModels: [String]

    /// A closure to check authentication status. Called only if `requiresAuthentication` is true.
    /// Returns a human-readable error string if auth is missing or invalid, nil if authenticated.
    public let checkAuthentication: (@Sendable () throws -> String?)

    public init(
        id: String,
        displayName: String,
        executableCandidates: [String],
        versionCommand: [String],
        minimumVersion: String,
        launchArguments: [String],
        requiresAuthentication: Bool = false,
        knownModels: [String] = [],
        checkAuthentication: @escaping (@Sendable () throws -> String?) = { nil }
    ) {
        self.id = id
        self.displayName = displayName
        self.executableCandidates = executableCandidates
        self.versionCommand = versionCommand
        self.minimumVersion = minimumVersion
        self.launchArguments = launchArguments
        self.requiresAuthentication = requiresAuthentication
        self.knownModels = knownModels
        self.checkAuthentication = checkAuthentication
    }

    // Built-in descriptors for the three standard providers.
    public static let claude = ProviderDescriptor(
        id: "claude",
        displayName: "Claude Code",
        executableCandidates: ["claude"],
        versionCommand: ["--version"],
        minimumVersion: "2.0.0",
        // Verified against 2.1.237. `--permission-prompt-tool` does NOT exist in this CLI and
        // passing it makes the process exit immediately; permissions go through the PreToolUse hook
        // instead (see PermissionBroker). `--print` is required for the non-interactive stream.
        // `--include-partial-messages` is deliberately absent until the decoder handles
        // `stream_event` records — see FR-18.
        launchArguments: [
            "--print",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
        ],
        requiresAuthentication: true,
        knownModels: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
    )

    public static let codex = ProviderDescriptor(
        id: "codex",
        displayName: "Codex",
        executableCandidates: ["codex"],
        versionCommand: ["version"],
        minimumVersion: "1.0.0",
        launchArguments: ["app-server"]
    )
}
