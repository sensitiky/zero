import Foundation

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

    public init(configuration: Configuration) {
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            do {
                for record in try reader.feed(chunk) {
                    continuation.yield(.record(record))
                }
            } catch {
                continuation.yield(.streamFailure(String(describing: error)))
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            continuation.yield(.diagnostic(text))
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        process.terminationHandler = { process in
            // Drain what is still in the pipes before finishing.
            //
            // `readabilityHandler` fires asynchronously, so a process that exits immediately — a
            // CLI rejecting a flag, say — can terminate before the handler has read a single byte.
            // Finishing the stream here without draining silently discarded that output, leaving
            // callers with an exit code and no explanation of it.
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            if let remaining = try? stdoutHandle.readToEnd(), !remaining.isEmpty {
                if let records = try? reader.feed(remaining) {
                    for record in records { continuation.yield(.record(record)) }
                }
            }
            if let trailing = reader.flush() {
                continuation.yield(.record(trailing))
            }
            if let remaining = try? stderrHandle.readToEnd(), !remaining.isEmpty,
               let text = String(data: remaining, encoding: .utf8) {
                continuation.yield(.diagnostic(text))
            }

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
        try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
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
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

/// Holds the accumulator across `readabilityHandler` invocations, which arrive on an arbitrary
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
