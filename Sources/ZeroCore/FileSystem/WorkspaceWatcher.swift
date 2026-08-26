import CoreServices
import Foundation

/// Watches a directory subtree for changes and calls back — coalesced by FSEvents itself, not
/// telling the caller *what* changed, only that something did under `root`. The caller already
/// knows how to re-read whatever it cares about (a directory listing, git status, an open file).
///
/// Built on FSEvents (`CoreServices`), not a third-party dependency: it's the only mechanism on
/// macOS that watches a whole subtree recursively. A `DispatchSource` file watcher needs one
/// descriptor per watched path and does not follow into a newly created subdirectory on its own —
/// wrong shape for "tell me about anything changing anywhere under this workspace."
public final class WorkspaceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    /// - parameter root: Directory to watch, recursively.
    /// - parameter latency: How long FSEvents coalesces rapid changes before calling back — several
    ///   saves in the same second (a build, a formatter, a git checkout) arrive as one call, not one
    ///   per file.
    /// - parameter onChange: Called on a background queue whenever something changed under `root`.
    ///   Never called synchronously from `init`. The caller hops back to its own actor/queue.
    public init?(root: URL, latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        // `self` is fully initialized above (`stream` defaults to `nil`), so it's safe to capture
        // from here on.
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        // Resolved, not the raw path: `NSTemporaryDirectory()`-style paths (and some worktree
        // parents) are themselves a symlink, and FSEvents watches the real path underneath —
        // handed the symlink, it silently reports nothing.
        let resolvedPath = root.resolvingSymlinksInPath().path

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [resolvedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            // Not `.ignoreSelf`: that flag filters events by which OS process caused them, and the
            // whole point here is to catch changes from *any* source — the agent subprocess, an
            // external editor, `git checkout` run by hand. Filtering by process would be the right
            // idea for a different problem than this one. Re-reading a directory listing on a
            // redundant event is cheap regardless.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }

        self.stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
    }

    private let onChange: @Sendable () -> Void

    deinit {
        stop()
    }

    /// Stops watching. Safe to call more than once; `deinit` calls it too, so an explicit call is
    /// only needed to stop watching before the owner itself goes away.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
