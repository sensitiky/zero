import CryptoKit
import Darwin
import Foundation

/// Answers Claude Code's `PreToolUse` hook with a decision the user made in the app.
///
/// Claude Code has no on-the-wire permission request (verified against 2.1.237 — see the
/// claude-code fixtures' PROVENANCE.md), so the only way to be asked before a tool runs is to sit
/// in a hook. The helper binary connects here over a per-session unix socket, this actor asks the
/// app, and the answer goes back for the helper to print.
///
/// Every failure path denies. A permission broker that fails open is worse than none, because it
/// still looks like protection.
public actor PermissionBroker {
    /// A decision plus the human origin that produced it.
    ///
    /// Allowing requires constructing one of these, and `PermissionOrigin` can only name a user
    /// action or a rule the user configured beforehand. That is what keeps tool output — which is
    /// attacker-influenced text — from being able to approve anything.
    public struct Resolution: Sendable {
        public let decision: HookResponse.Decision
        public let origin: PermissionOrigin

        public init(decision: HookResponse.Decision, origin: PermissionOrigin) {
            self.decision = decision
            self.origin = origin
        }
    }

    /// How a request ended. Only `.resolved` can carry an allow.
    public enum Outcome: Sendable, Equatable {
        case resolved(decision: HookResponse.Decision)
        case deniedByTimeout
        case deniedByBroker(String)

        var decision: HookResponse.Decision {
            switch self {
            case .resolved(let decision): return decision
            case .deniedByTimeout, .deniedByBroker: return .deny
            }
        }

        var reason: String {
            switch self {
            case .resolved(.allow): return "Zero: allowed by user"
            case .resolved(.deny): return "Zero: denied by user"
            case .deniedByTimeout: return "Zero: no answer before timeout"
            case .deniedByBroker(let why): return "Zero: \(why)"
            }
        }
    }

    public typealias PermissionHandler = @Sendable (PermissionRequest) async -> Resolution

    public enum BrokerError: Error, Sendable {
        case socketUnavailable(String)
        /// The socket path exceeded `sun_path`. Carries the path so the fix is obvious: choose a
        /// shorter sockets directory, e.g. `defaultSocketsDirectory()`.
        case pathTooLong(path: String, limit: Int)
    }

    /// 90 seconds: long enough to read a shell command and think, short enough that a dialog left
    /// open behind another window does not pin an agent for the rest of the day.
    public static let defaultTimeout: TimeInterval = 90

    private let handler: PermissionHandler
    private let socketsDirectory: URL
    private let timeout: TimeInterval
    private var listeners: [String: SessionListener] = [:]

    public init(
        socketsDirectory: URL,
        timeout: TimeInterval = PermissionBroker.defaultTimeout,
        handler: @escaping PermissionHandler
    ) {
        self.socketsDirectory = socketsDirectory
        self.timeout = timeout
        self.handler = handler
    }

    /// A short directory for sockets.
    ///
    /// `sun_path` is 104 bytes on Darwin, and the obvious homes blow through it: the system temp
    /// directory alone is ~50 characters and Application Support is worse. This lives directly
    /// under the user's cache directory with a fixed short name so the budget goes to the socket.
    public static func defaultSocketsDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        return base.appendingPathComponent("zero-sock", isDirectory: true)
    }

    /// The socket for a session.
    ///
    /// The filename is a 16-hex digest of the session id rather than the id itself, because a UUID
    /// plus a long parent path exceeds `sun_path`. Deterministic, so the app and the helper agree
    /// without passing extra state.
    public func socketPath(for sessionID: String) -> String {
        socketsDirectory.appendingPathComponent("\(Self.shortName(for: sessionID)).sock").path
    }

    static func shortName(for sessionID: String) -> String {
        SHA256.hash(data: Data(sessionID.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Binds, chmods and *listens* on the session's socket, then serves connections until stopped.
    @discardableResult
    public func startSession(id sessionID: String) throws -> String {
        try FileManager.default.createDirectory(
            at: socketsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = socketPath(for: sessionID)
        try? FileManager.default.removeItem(atPath: path)

        guard let resolved = SocketIO.address(path: path) else {
            throw BrokerError.pathTooLong(path: path, limit: SocketIO.maxSocketPathBytes)
        }
        var addr = resolved.0
        let len = resolved.1

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.socketUnavailable("socket() failed") }

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        guard bound >= 0 else {
            Darwin.close(fd)
            throw BrokerError.socketUnavailable("bind() failed for \(path)")
        }
        // Owner-only: any local process that can connect can answer permission prompts.
        // A receive timeout on the listening socket makes `accept` return periodically so the
        // thread can notice it has been stopped. The ceiling is a 250 ms shutdown latency; a kqueue
        // self-pipe would remove it, and is worth doing only if that latency ever shows up.
        SocketIO.setTimeouts(fd, SessionListener.acceptPollInterval)
        guard Darwin.chmod(path, 0o600) >= 0, Darwin.listen(fd, 16) >= 0 else {
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
            throw BrokerError.socketUnavailable("chmod/listen failed for \(path)")
        }

        let listener = SessionListener(fd: fd, path: path)
        listeners[sessionID] = listener
        listener.start { [weak self] client in
            Task { await self?.serve(client: client, expecting: sessionID) }
        }
        return path
    }

    public func stopSession(id sessionID: String) {
        listeners.removeValue(forKey: sessionID)?.stop()
    }

    public func stopAll() {
        for (_, listener) in listeners { listener.stop() }
        listeners.removeAll()
    }

    /// Reads one request off a connection, answers it, and closes.
    private func serve(client: Int32, expecting sessionID: String) async {
        defer { Darwin.close(client) }
        SocketIO.setTimeouts(client, timeout + 5)

        guard let payload = SocketIO.readFrame(client) else {
            reply(client, .deniedByBroker("unreadable request"))
            return
        }
        guard let request = try? JSONDecoder().decode(HookRequest.self, from: payload) else {
            reply(client, .deniedByBroker("malformed request"))
            return
        }
        // The connection arrived on this session's own socket, so a mismatch means the payload is
        // lying about who it is. Deny rather than route it somewhere.
        guard request.sessionID == Self.shortName(for: sessionID), listeners[sessionID] != nil else {
            reply(client, .deniedByBroker("unknown session"))
            return
        }
        reply(client, await decide(request))
    }

    private func decide(_ request: HookRequest) async -> Outcome {
        let permissionRequest = PermissionRequest(
            id: request.requestID,
            toolName: request.toolName,
            // Rendered as data. Never parsed for instructions, never executed.
            detail: request.toolInput,
            options: [
                PermissionOption(id: "allow_once", kind: .allowOnce, label: "Allow Once"),
                PermissionOption(id: "allow_always", kind: .allowAlways, label: "Allow Always"),
                PermissionOption(id: "deny_once", kind: .denyOnce, label: "Deny"),
                PermissionOption(id: "deny_always", kind: .denyAlways, label: "Deny Always"),
            ]
        )

        let handler = self.handler
        let timeout = self.timeout
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .resolved(decision: await handler(permissionRequest).decision) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .deniedByTimeout
            }
            let first = await group.next() ?? .deniedByBroker("no outcome")
            group.cancelAll()
            return first
        }
    }

    private func reply(_ client: Int32, _ outcome: Outcome) {
        let response = HookResponse(decision: outcome.decision, reason: outcome.reason)
        _ = SocketIO.writeFrame(client, response.stdoutPayload())
    }
}

/// Owns a listening socket and accepts on a dedicated thread.
///
/// `accept` blocks, so it cannot run on a cooperative-pool thread without risking starvation of
/// the very actor that has to answer.
private final class SessionListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let lock = NSLock()
    private var stopped = false

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    static let acceptPollInterval: TimeInterval = 0.25

    func start(onConnection: @escaping @Sendable (Int32) -> Void) {
        let thread = Thread { [self] in
            while !isStopped {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else {
                    // EAGAIN from the poll timeout, or EBADF once the socket is closed.
                    if isStopped { return }
                    continue
                }
                guard !isStopped else {
                    Darwin.close(client)
                    return
                }
                onConnection(client)
            }
        }
        thread.name = "zero.permission-listener"
        thread.start()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        try? FileManager.default.removeItem(atPath: path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    deinit { stop() }
}
