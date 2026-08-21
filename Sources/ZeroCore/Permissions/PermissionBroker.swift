import Foundation
import Darwin

/// Brokers permission decisions between the Claude Code hook helper and the app.
///
/// For each session, the broker tracks active sessions. The helper
/// calls `processRequest` to ask for a permission decision, which goes to the app via the
/// handler callback. The app user responds, and the decision comes back to the helper.
///
/// The broker fails closed: if the handler does not respond within the timeout, if the
/// response is malformed, or if anything else goes wrong — the helper receives a deny.
public actor PermissionBroker: Sendable {
    public enum BrokerError: Error, Sendable {
        case sessionNotFound
        case invalidRequest
    }

    /// The callback the app implements to handle permission requests.
    ///
    /// The handler receives a PermissionRequest and must eventually call one of the completions
    /// with a PermissionOrigin. If neither completion is called within the timeout, the broker
    /// denies the request.
    public typealias PermissionHandler = @Sendable (
        _ request: PermissionRequest,
        _ allowCompletion: @escaping @Sendable (PermissionOrigin) -> Void,
        _ denyCompletion: @escaping @Sendable (PermissionOrigin) -> Void
    ) -> Void

    /// The maximum time to wait for the app to make a decision. Injected for testing.
    private let timeout: TimeInterval

    /// The app's callback to handle permission requests.
    private let handler: PermissionHandler

    /// The directory under which session sockets are created.
    private let socketsDirectory: URL

    /// Active sessions. Maps session ID to socket path.
    private var activeSessions: [String: String] = [:]

    /// Creates a permission broker.
    ///
    /// - Parameters:
    ///   - handler: Called when a permission request arrives. Must call one of the completions.
    ///   - socketsDirectory: Directory where session sockets will be created.
    ///   - timeout: Maximum time to wait for the app's decision (default: 30 seconds). Injected for testing.
    public init(
        handler: @escaping PermissionHandler,
        socketsDirectory: URL,
        timeout: TimeInterval = 30
    ) {
        self.handler = handler
        self.socketsDirectory = socketsDirectory
        self.timeout = timeout
    }

    /// Starts listening for permission requests for a session.
    ///
    /// Creates and binds a unix domain socket at `socketsDirectory/sessionID.sock`.
    /// The socket is created with owner-only permissions (0o600).
    public func startSession(id sessionID: String) throws {
        // Ensure the sockets directory exists.
        try FileManager.default.createDirectory(at: socketsDirectory, withIntermediateDirectories: true)

        let socketPath = socketsDirectory.appendingPathComponent("\(sessionID).sock").path

        // Clean up any stale socket.
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create and bind the socket.
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw BrokerError.invalidRequest
        }

        defer {
            Darwin.close(socketFD)
        }

        // Bind to the path.
        var socketAddr = sockaddr_un()
        socketAddr.sun_family = sa_family_t(AF_UNIX)

        // Copy the path into sun_path, respecting the buffer size.
        let pathCString = socketPath.withCString { $0 }
        let maxLen = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        memcpy(&socketAddr.sun_path, pathCString, min(socketPath.count, maxLen))

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: socketAddr) { addr in
            Darwin.bind(socketFD, UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr.self), len)
        }

        guard bindResult >= 0 else {
            try? FileManager.default.removeItem(atPath: socketPath)
            throw BrokerError.invalidRequest
        }

        // Set socket permissions to owner-only (0o600).
        guard Darwin.chmod(socketPath, 0o600) >= 0 else {
            try? FileManager.default.removeItem(atPath: socketPath)
            throw BrokerError.invalidRequest
        }

        // Mark the session as active.
        activeSessions[sessionID] = socketPath
    }

    /// Stops listening for a session and cleans up its socket.
    public func stopSession(id sessionID: String) {
        guard let socketPath = activeSessions.removeValue(forKey: sessionID) else {
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Processes a permission request.
    func processRequest(_ request: HookRequest, responseCallback: @escaping @Sendable (Decision) -> Void) async {
        // Validate the session exists.
        guard activeSessions[request.sessionID] != nil else {
            responseCallback(.deny)
            return
        }

        // Tool input is opaque JSON, treated as data for rendering (not interpretation).
        let toolInput = request.toolInput

        let permissionRequest = PermissionRequest(
            id: request.requestID,
            toolName: request.toolName,
            detail: toolInput,
            options: [
                PermissionOption(id: "allow_once", kind: .allowOnce, label: "Allow Once"),
                PermissionOption(id: "allow_always", kind: .allowAlways, label: "Allow Always"),
                PermissionOption(id: "deny_once", kind: .denyOnce, label: "Deny Once"),
                PermissionOption(id: "deny_always", kind: .denyAlways, label: "Deny Always"),
            ]
        )

        // Wait for the app's decision with a timeout.
        let decision = await withTaskGroup(of: Decision.self) { group -> Decision in
            group.addTask {
                return await self.waitForDecision(permissionRequest)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                return .deny
            }

            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return .deny
        }

        responseCallback(decision)
    }

    /// Waits for the app to make a decision on the permission request.
    private func waitForDecision(_ request: PermissionRequest) async -> Decision {
        await withCheckedContinuation { continuation in
            let allow: @Sendable (PermissionOrigin) -> Void = { (_: PermissionOrigin) in
                continuation.resume(returning: .allow)
            }
            let deny: @Sendable (PermissionOrigin) -> Void = { (_: PermissionOrigin) in
                continuation.resume(returning: .deny)
            }

            handler(request, allow, deny)
        }
    }

    enum Decision: Sendable {
        case allow
        case deny
    }
}
