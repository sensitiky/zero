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
        checkAuthentication: @escaping (@Sendable () throws -> String?) = { nil }
    ) {
        self.id = id
        self.displayName = displayName
        self.executableCandidates = executableCandidates
        self.versionCommand = versionCommand
        self.minimumVersion = minimumVersion
        self.launchArguments = launchArguments
        self.requiresAuthentication = requiresAuthentication
        self.checkAuthentication = checkAuthentication
    }

    // Built-in descriptors for the three standard providers.
    static let claude = ProviderDescriptor(
        id: "claude",
        displayName: "Claude Code",
        executableCandidates: ["claude"],
        versionCommand: ["--version"],
        minimumVersion: "2.0.0",
        launchArguments: [
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio"
        ],
        requiresAuthentication: true
    )

    static let codex = ProviderDescriptor(
        id: "codex",
        displayName: "Codex",
        executableCandidates: ["codex"],
        versionCommand: ["version"],
        minimumVersion: "1.0.0",
        launchArguments: ["app-server"]
    )
}
