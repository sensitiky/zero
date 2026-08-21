import Foundation

/// Errors from Git operations.
public enum GitError: Error, Sendable {
    /// The repository at the given path has uncommitted changes.
    case dirtyRepository(repoPath: String)

    /// The provided path or worktree path falls outside the repository root.
    case pathOutsideRepository(path: String, repoRoot: String)

    /// The given path is not a git repository.
    case notARepository(path: String)

    /// Git command failed with the given exit code and stderr.
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    /// Unable to derive a valid slug from the prompt.
    case invalidSlug(prompt: String)

    /// A worktree already exists at the expected path.
    case worktreeAlreadyExists(path: String)

    /// The worktree cannot be removed.
    case cannotRemoveWorktree(path: String, reason: String)

    /// Base branch resolution failed.
    case cannotResolveBranch(reason: String)
}
