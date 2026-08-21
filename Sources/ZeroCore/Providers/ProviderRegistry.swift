import Foundation

/// Status of a provider: whether it is available and usable.
public enum ProviderStatus: Sendable, Equatable {
    /// Provider is available and authenticated (if required).
    case available(version: String)

    /// Provider executable not found in any candidate directory.
    case notInstalled(reason: String)

    /// Provider version is older than the minimum required.
    case versionTooOld(installed: String, minimum: String, reason: String)

    /// Provider is present but not authenticated.
    case notAuthenticated(reason: String)

    /// Provider binary was found but could not be executed or version could not be determined.
    case resolutionFailed(reason: String)
}

/// Discovers and validates AI provider executables, and builds their launch configurations.
///
/// The registry is injectable for testing: pass custom `resolveExecutable` and `getVersion`
/// closures to avoid depending on what is installed on the test machine.
public final class ProviderRegistry: Sendable {
    /// Resolves an executable candidate to an absolute path, or returns nil if not found.
    /// Must validate that the result is an executable regular file. The default implementation
    /// probes candidate directories and the filesystem.
    public typealias ExecutableResolver = @Sendable (String, [URL]) throws -> URL?

    /// Invokes a command to get its version string. The default reads stdout from a subprocess.
    public typealias VersionGetter = @Sendable (URL, [String]) throws -> String?

    private let resolveExecutable: ExecutableResolver
    private let getVersion: VersionGetter
    private let candidateDirectories: [URL]

    /// Creates a registry with optional dependency injection for testing.
    ///
    /// - Parameters:
    ///   - candidateDirectories: Directories to search for provider executables. Must be absolute.
    ///     Searched in order; the first match wins. Default: /usr/local/bin, /opt/homebrew/bin, /usr/bin, /bin.
    ///   - resolveExecutable: Closure to resolve a candidate string to an absolute path.
    ///     Default: probes candidate directories, then the FileManager.
    ///   - getVersion: Closure to invoke a version command and parse the result.
    ///     Default: runs the command as a subprocess and reads stdout.
    public init(
        candidateDirectories: [URL]? = nil,
        resolveExecutable: ExecutableResolver? = nil,
        getVersion: VersionGetter? = nil
    ) {
        self.candidateDirectories = candidateDirectories ?? [
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin")
        ]
        self.resolveExecutable = resolveExecutable ?? Self.defaultResolveExecutable
        self.getVersion = getVersion ?? Self.defaultGetVersion
    }

    /// Returns the status of a provider: available, not installed, version mismatch, or error.
    /// Never throws; all failures are expressed as status values.
    public func status(of descriptor: ProviderDescriptor) -> ProviderStatus {
        // Resolve the executable.
        guard let executableURL = (try? resolveExecutable(
            descriptor.id,
            candidateDirectories
        )) else {
            return .notInstalled(
                reason: "Could not find \(descriptor.displayName) in candidate directories."
            )
        }

        // Get the version.
        guard let versionString = (try? getVersion(executableURL, descriptor.versionCommand)) else {
            return .resolutionFailed(
                reason: "Could not determine \(descriptor.displayName) version. "
                    + "Is it installed correctly?"
            )
        }

        let installed = parseVersion(versionString)
        let minimum = parseVersion(descriptor.minimumVersion)

        // Check version.
        if !versionMeetsMinimum(installed, minimum) {
            return .versionTooOld(
                installed: versionString,
                minimum: descriptor.minimumVersion,
                reason: "\(descriptor.displayName) version \(versionString) is too old. "
                    + "Minimum required: \(descriptor.minimumVersion)."
            )
        }

        // Check authentication if required.
        if descriptor.requiresAuthentication {
            do {
                if let authError = try descriptor.checkAuthentication() {
                    return .notAuthenticated(reason: authError)
                }
            } catch {
                return .resolutionFailed(
                    reason: "Could not check authentication for \(descriptor.displayName): "
                        + "\(error)"
                )
            }
        }

        return .available(version: versionString)
    }

    /// Builds an `AgentProcess.Configuration` for the given descriptor, assuming it is available.
    /// The caller must verify the provider's status before calling this — it does no validation.
    public func configuration(
        for descriptor: ProviderDescriptor,
        workingDirectory: URL
    ) throws -> AgentProcess.Configuration {
        guard let executableURL = try? resolveExecutable(
            descriptor.id,
            candidateDirectories
        ) else {
            throw RegistryError("Could not resolve \(descriptor.displayName) executable")
        }

        return AgentProcess.Configuration(
            executable: executableURL,
            arguments: descriptor.launchArguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - Default implementations

    /// Default executable resolver: probes candidate directories, validating that the result
    /// is an executable regular file.
    static let defaultResolveExecutable: ExecutableResolver = { candidate, directories in
        // If the candidate is already an absolute path, validate it directly.
        if candidate.hasPrefix("/") {
            let url = URL(fileURLWithPath: candidate)
            guard isExecutableFile(url) else { return nil }
            return url
        }

        // Probe candidate directories.
        for directory in directories {
            let url = directory.appendingPathComponent(candidate)
            if isExecutableFile(url) {
                return url
            }
        }

        return nil
    }

    /// Default version getter: runs the executable with the version command and parses the
    /// first line of output.
    static let defaultGetVersion: VersionGetter = { executable, command in
        let process = Process()
        process.executableURL = executable
        process.arguments = command

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Return the first non-empty line.
            return output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(
                in: .whitespaces
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func isExecutableFile(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            return false
        }

        return fm.isExecutableFile(atPath: url.path)
    }

    /// Parses a version string into (major, minor, patch).
    private func parseVersion(_ versionString: String) -> (Int, Int, Int) {
        let components = versionString
            .split(separator: ".")
            .compactMap { Int($0) }

        if components.count >= 3 {
            return (components[0], components[1], components[2])
        } else if components.count == 2 {
            return (components[0], components[1], 0)
        } else if components.count == 1 {
            return (components[0], 0, 0)
        }
        return (0, 0, 0)
    }

    /// Returns true if installed version >= minimum version.
    private func versionMeetsMinimum(
        _ installed: (Int, Int, Int),
        _ minimum: (Int, Int, Int)
    ) -> Bool {
        if installed.0 != minimum.0 { return installed.0 > minimum.0 }
        if installed.1 != minimum.1 { return installed.1 > minimum.1 }
        return installed.2 >= minimum.2
    }
}

/// Error type for ProviderRegistry operations.
struct RegistryError: Error, Sendable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
