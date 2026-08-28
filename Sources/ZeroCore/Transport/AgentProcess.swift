import Foundation

/// Ignoring `SIGPIPE` process-wide, once.
///
/// Writing to a pipe whose reader has already gone away — a provider CLI that exited, or one that
/// never reads stdin at all — delivers `SIGPIPE`, and the default disposition for that signal is to
/// terminate the process. Not the session: the whole app. `Process`/`Pipe` do not install a handler
/// for this on their own, so a single dead agent could take down every other session with it.
private let sigpipeIgnored: Bool = {
    signal(SIGPIPE, SIG_IGN)
    return true
}()

/// A long-lived provider CLI, spoken to over pipes.
///
/// No PTY: this is the whole reason Zero can render native chat instead of embedding a terminal.
/// One process per session, stdin held open across turns — providers treat a closed stdin as
/// end-of-conversation, so a process per message would silently lose context.
public actor AgentProcess {
    public enum Output: Sendable {
        case record(Data)
        case diagnostic(String)
        case exited(code: Int32, reason: Process.TerminationReason)
        case streamFailure(String)
    }

    public struct Configuration: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: URL
        public var maxLineBytes: Int

        public init(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            workingDirectory: URL,
            maxLineBytes: Int = 64 << 20
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.maxLineBytes = maxLineBytes
        }
    }

    public struct NotRunning: Error, Sendable {}

    public nonisolated let output: AsyncStream<Output>

    private nonisolated let continuation: AsyncStream<Output>.Continuation
    private let configuration: Configuration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let reader: LineReader
    private var running = false

    /// Reaches zero once both the stdout and stderr read loops below have observed EOF.
    /// `terminationHandler` waits on it before yielding `.exited` — see `start()` for why a
    /// blocking read-to-EOF loop, not `FileHandle.readabilityHandler`, is what actually closes
    /// the race between a process exiting right after writing and its output being drained
    /// (`echo first; echo second` losing "second" is exactly what this fixes).
    private let readersDone = DispatchGroup()

    public init(configuration: Configuration) {
        _ = sigpipeIgnored
        self.configuration = configuration
        self.reader = LineReader(maxLineBytes: configuration.maxLineBytes)
        var captured: AsyncStream<Output>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    public var isRunning: Bool { running }

    public func start() throws {
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let continuation = self.continuation
        let reader = self.reader
        let readersDone = self.readersDone

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // A blocking read-to-EOF loop, one per pipe, each on its own queue so neither starves the
        // other. `availableData` returns as soon as *any* data is ready — so this still streams
        // live, chunk by chunk — and returns empty exactly at EOF, which a pipe only reaches once
        // every writer has closed it, i.e. once the child process has actually exited. That is a
        // stronger, race-free signal than `FileHandle.readabilityHandler`: a handler only gets
        // *notified* data is ready, on its own asynchronous schedule, so a process exiting right
        // after writing (`echo first; echo second`) could race the notification against
        // termination and lose the last write. Reading to true EOF can't lose anything — there is
        // nothing left to race against once the loop itself has seen the pipe close.
        readersDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readersDone.leave() }
            while true {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { break }
                do {
                    for record in try reader.feed(chunk) {
                        continuation.yield(.record(record))
                    }
                } catch {
                    continuation.yield(.streamFailure(String(describing: error)))
                    break
                }
            }
            if let trailing = reader.flush() {
                continuation.yield(.record(trailing))
            }
        }

        readersDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readersDone.leave() }
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                continuation.yield(.diagnostic(text))
            }
        }

        process.terminationHandler = { process in
            // Waits for both loops above to have actually observed EOF — not merely for the
            // process to have exited — before reporting it, so every byte the child wrote is
            // yielded ahead of `.exited`.
            readersDone.wait()

            continuation.yield(
                .exited(code: process.terminationStatus, reason: process.terminationReason)
            )
            continuation.finish()
        }

        try process.run()
        running = true
    }

    /// Writes one NDJSON record. The newline is this method's business, not the caller's.
    public func send(_ record: Data) throws {
        guard running else { throw NotRunning() }
        var payload = record
        payload.append(UInt8(ascii: "\n"))
        // `write(2)` returns EPIPE here rather than raising, now that SIGPIPE is ignored. Turned
        // into a normal Swift error instead of a process-wide crash.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            throw WriteFailed(underlying: error)
        }
    }

    public struct WriteFailed: Error, Sendable {
        public let underlying: any Error
    }

    /// Interrupts the turn in progress without ending the session.
    ///
    /// SIGINT, not SIGTERM. Claude Code's documented behavior is that SIGTERM terminates the whole
    /// process tree and exits 143 — that ends the session and loses the conversation — while SIGINT
    /// ends the turn in flight. This is the fallback for providers whose protocol has no cancel
    /// record; Codex (`turn/interrupt`) and ACP (`session/cancel`) should be cancelled in band
    /// instead, because an in-band cancel tells the agent why it stopped.
    public func interrupt() {
        guard running else { return }
        process.interrupt()
    }

    /// Ends the conversation politely: providers exit once stdin closes.
    public func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        guard running else { return }
        running = false
        if process.isRunning { process.terminate() }
    }
}

/// Holds the accumulator across the stdout read loop's invocations, which happen on a background
/// queue and therefore cannot touch actor state directly.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: LineAccumulator

    init(maxLineBytes: Int) {
        self.accumulator = LineAccumulator(maxLineBytes: maxLineBytes)
    }

    func feed(_ chunk: Data) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return try accumulator.append(chunk)
    }

    func flush() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.flush()
    }
}
