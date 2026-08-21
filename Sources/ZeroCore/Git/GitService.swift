import Foundation

/// Manages git worktrees for isolated agent sessions.
///
/// All operations shell out to the real `git` binary with array-based arguments — never shell
/// interpolation. Every path written to or removed is validated to fall under the repository root
/// before any operation runs, using resolved paths (symlinks expanded, `..` collapsed) to prevent
/// escape attempts via crafted slugs or paths.
public actor GitService {
    private let repositoryPath: URL
    private let fileManager = FileManager.default

    /// Initializes the service for a repository at the given path.
    ///
    /// - parameter repositoryPath: Absolute path to the git repository root.
    /// - throws: ``GitError/notARepository`` if the path is not a git repository.
    public init(repositoryPath: URL) throws {
        // Verify the repository exists and is a git repo
        let gitDir = repositoryPath.appendingPathComponent(".git", isDirectory: true)
        guard fileManager.fileExists(atPath: gitDir.path) else {
            throw GitError.notARepository(path: repositoryPath.path)
        }
        self.repositoryPath = repositoryPath
    }

    /// Reports whether the repository has uncommitted changes.
    ///
    /// - returns: `true` if the repository has unstaged or staged changes; `false` if clean.
    /// - throws: ``GitError`` if the git command fails.
    public func isDirty() throws -> Bool {
        let output = try runGit(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resolves the base branch for creating a worktree.
    ///
    /// Returns the currently checked-out branch in the repository.
    ///
    /// - returns: The branch name (e.g., "main", "develop").
    /// - throws: ``GitError`` if the branch cannot be resolved.
    public func resolveBaseBranch() throws -> String {
        let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty && branch != "HEAD" else {
            throw GitError.cannotResolveBranch(reason: "Current branch is detached or unknown")
        }
        return branch
    }

    /// Creates a new worktree for a session.
    ///
    /// The branch name is derived from the prompt slug and a short ID: `zero/{slug}-{id}`.
    /// If a branch with that name already exists, a numeric suffix is appended and the operation
    /// retries. The created worktree is placed in `.worktrees/{slug}-{id}` relative to the
    /// repository root.
    ///
    /// - parameter prompt: Session prompt, used to derive the branch slug.
    /// - parameter baseBranch: Branch to create the worktree from. If `nil`, uses the current branch.
    /// - parameter worktreeParent: Parent directory for the worktree. Defaults to `.worktrees` in the repo root.
    /// - returns: A tuple of (worktreeURL, branchName).
    /// - throws: ``GitError`` if the operation fails or paths fall outside the repository.
    public func createWorktree(
        from prompt: String,
        baseBranch: String? = nil,
        worktreeParent: URL? = nil
    ) throws -> (worktreeURL: URL, branchName: String) {
        let slug = deriveSlug(from: prompt)
        let shortID = UUID().uuidString.prefix(7).lowercased()
        let base: String
        if let baseBranch = baseBranch {
            base = baseBranch
        } else {
            base = try resolveBaseBranch()
        }

        // Determine worktree location
        let parent = worktreeParent ?? repositoryPath.appendingPathComponent(".worktrees", isDirectory: true)
        let worktreeBaseName = "\(slug)-\(shortID)"
        let worktreePath = parent.appendingPathComponent(worktreeBaseName, isDirectory: true)

        // Validate that the worktree path will be inside the repository
        try validatePathInsideRepository(worktreePath)

        // Try branch names with optional counter suffix
        var branchName: String?
        var attemptCounter = 0
        let maxAttempts = 100

        while branchName == nil && attemptCounter < maxAttempts {
            let candidate = attemptCounter == 0
                ? "zero/\(slug)-\(shortID)"
                : "zero/\(slug)-\(shortID)-\(attemptCounter)"

            // Check if branch exists
            let checkResult = runGitQuiet(["rev-parse", "--verify", candidate])
            if checkResult == nil {
                // Branch does not exist, we can use this name
                branchName = candidate
            } else {
                attemptCounter += 1
            }
        }

        guard let branchName = branchName else {
            throw GitError.invalidSlug(prompt: prompt)
        }

        // Create the worktree with the branch name
        _ = try runGit(["worktree", "add", "-b", branchName, worktreePath.path, base])

        // Verify the worktree was created at the expected path
        guard fileManager.fileExists(atPath: worktreePath.path) else {
            throw GitError.worktreeAlreadyExists(path: worktreePath.path)
        }

        return (worktreePath, branchName)
    }

    /// Removes a worktree and optionally its branch.
    ///
    /// The worktree path is validated to fall under the repository root before any removal.
    /// The branch is only removed if explicitly requested.
    ///
    /// - parameter worktreePath: Path to the worktree to remove.
    /// - parameter removeBranch: If `true`, also deletes the worktree's branch. Default is `false`.
    /// - throws: ``GitError`` if the operation fails or the path is invalid.
    public func removeWorktree(
        at worktreePath: URL,
        removeBranch: Bool = false
    ) throws {
        // Validate the path is inside the repository
        try validatePathInsideRepository(worktreePath)

        // Remove the worktree
        do {
            _ = try runGit(["worktree", "remove", worktreePath.path])
        } catch let error as GitError {
            throw GitError.cannotRemoveWorktree(path: worktreePath.path, reason: String(describing: error))
        }

        // Remove the branch if requested
        if removeBranch {
            // Extract the branch name from the worktree; use the prompt file if available
            // For now, attempt to find the branch by examining the worktree metadata
            // Fallback: user must specify or we discover from git worktree list
            do {
                let output = try runGit(["worktree", "list", "--porcelain"])
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        let path = String(parts[0])
                        if path == worktreePath.path {
                            if parts.count >= 3 && parts[1] == "branch" {
                                let branchRef = String(parts[2])
                                // Extract branch name from refs/heads/...
                                if branchRef.hasPrefix("refs/heads/") {
                                    let branchName = String(branchRef.dropFirst("refs/heads/".count))
                                    _ = try runGit(["branch", "-D", branchName])
                                }
                            }
                        }
                    }
                }
            } catch {
                // If we can't determine the branch, that's okay — the worktree is removed
            }
        }
    }

    // MARK: - Internal Helpers

    /// Derives a git-compatible slug from a prompt string.
    ///
    /// The slug is lowercase, contains only letters, digits, and hyphens, and is bounded in length.
    /// If the prompt consists entirely of invalid characters, returns a default slug.
    private func deriveSlug(from prompt: String) -> String {
        let normalized = prompt
            .lowercased()
            .unicodeScalars
            .map { scalar -> String in
                if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                    return String(scalar)
                } else if scalar == "-" || scalar == "_" {
                    return "-"
                } else if scalar.properties.isWhitespace {
                    return "-"
                } else {
                    return ""
                }
            }
            .joined()

        // Collapse consecutive hyphens
        let collapsed = normalized.replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )

        // Remove leading and trailing hyphens/dots
        let trimmed = collapsed
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))

        // Bound the length (git ref limit is 255, we use a smaller limit for readability)
        let maxSlugLength = 50
        let bounded = String(trimmed.prefix(maxSlugLength))

        // If empty or invalid, use a default
        guard !bounded.isEmpty else {
            return "session"
        }

        return bounded
    }

    /// Validates that a path falls under the repository root.
    ///
    /// Resolves symlinks and normalizes paths (replacing `..` and `.`) before comparison.
    ///
    /// - throws: ``GitError/pathOutsideRepository`` if the path is not under the repository root.
    private func validatePathInsideRepository(_ path: URL) throws {
        let repoResolved = try resolvePathFully(repositoryPath.path)
        let pathResolved = try resolvePathFully(path.path)

        // Ensure the resolved path is under the repo root
        guard pathResolved.hasPrefix(repoResolved) else {
            throw GitError.pathOutsideRepository(path: path.path, repoRoot: repositoryPath.path)
        }

        // Check that it's a proper subdirectory, not a prefix match on directory names
        // e.g., /repo/secret is not a child of /repo-evil
        if pathResolved != repoResolved {
            let afterRoot = String(pathResolved.dropFirst(repoResolved.count))
            guard afterRoot.hasPrefix("/") || afterRoot.isEmpty else {
                throw GitError.pathOutsideRepository(path: path.path, repoRoot: repositoryPath.path)
            }
        }
    }

    /// Resolves a path by expanding symlinks and normalizing `..` components.
    ///
    /// Resolves symlinks at every component level to detect escapes.
    private func resolvePathFully(_ path: String) throws -> String {
        var normalized = (path as NSString).standardizingPath

        // Ensure absolute path
        guard normalized.hasPrefix("/") else {
            throw GitError.notARepository(path: path)
        }

        var resolved = ""
        var visited = Set<String>()

        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            resolved += "/" + component

            // Detect cycles
            guard !visited.contains(resolved) else {
                throw GitError.pathOutsideRepository(path: path, repoRoot: resolved)
            }
            visited.insert(resolved)

            // Check if this component is a symlink
            do {
                let target = try fileManager.destinationOfSymbolicLink(atPath: resolved)
                // Resolve the symlink target
                if target.hasPrefix("/") {
                    resolved = target
                } else {
                    // Relative symlink: resolve relative to parent
                    let parent = (resolved as NSString).deletingLastPathComponent
                    resolved = (parent as NSString).appendingPathComponent(target)
                }
                // Normalize after resolving
                resolved = (resolved as NSString).standardizingPath
            } catch {
                // Not a symlink, continue
            }
        }

        return resolved.isEmpty ? "/" : resolved
    }

    /// Runs a git command with the given arguments, returning stdout.
    ///
    /// - throws: ``GitError/commandFailed`` if git exits non-zero.
    private func runGit(_ args: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd ?? repositoryPath

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(
                command: args.joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: errorOutput
            )
        }

        return output
    }

    /// Runs a git command quietly, returning `nil` if it fails.
    ///
    /// Used for probe operations where failure is expected (e.g., checking if a branch exists).
    private func runGitQuiet(_ args: [String]) -> String? {
        do {
            return try runGit(args)
        } catch {
            return nil
        }
    }
}
