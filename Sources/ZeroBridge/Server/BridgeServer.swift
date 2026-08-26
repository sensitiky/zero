import Foundation
import Network
import Synchronization

/// The listener, and everything that lives as long as it does (FR-1, FR-2, FR-3).
///
/// One `NWListener` on one port, all interfaces — the point is the LAN. It is off until something
/// calls `start`, and `stop` closes every open connection, because a listener that outlives the
/// switch that turned it on is a listener nobody remembers is running.
public actor BridgeServer {

    public enum Failure: Error, Sendable, Equatable {
        case invalidPort(UInt16)
        case listenerFailed(String)
    }

    private let handler: any BridgeRequestHandling
    private let pingInterval: Duration

    /// The fan-out. Held here so `stop` can close every client, and exposed so the adapter can
    /// publish into it without going through the server.
    public let hub: EventHub

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [UUID: Connection] = [:]

    private struct Connection {
        var task: Task<Void, Never>
        var socket: Socket
        var connection: BridgeConnection
    }

    /// Everything the bridge does happens here, and it is not the main queue (FR-6).
    private let queue = DispatchQueue(label: "tech.incu.zero.bridge", qos: .userInitiated)

    public init(
        handler: any BridgeRequestHandling,
        hub: EventHub = EventHub(),
        pingInterval: Duration = BridgeLimits.pingInterval
    ) {
        self.handler = handler
        self.hub = hub
        self.pingInterval = pingInterval
    }

    public var isListening: Bool { listener != nil }

    /// The port actually bound. With `port: 0` the system picks one, which is how the tests bind
    /// without ever colliding with a running Zero.
    public var port: UInt16? { boundPort }

    public var clientCount: Int { hub.clientCount }

    /// Idempotent: starting an already-started server returns the port it is already on rather than
    /// building a second listener. Two listeners on one toggle is the thing most likely to go wrong
    /// here, and it does not fail loudly — it leaks a port that nothing can close.
    @discardableResult
    public func start(port requested: UInt16 = BridgeLimits.defaultPort) async throws -> UInt16 {
        if let boundPort { return boundPort }

        guard let endpointPort = NWEndpoint.Port(rawValue: requested) else {
            throw Failure.invalidPort(requested)
        }

        let parameters = NWParameters.tcp
        // So a restart on the same port does not have to wait out TIME_WAIT — start/stop/start is
        // one click, and it has to work the third time too.
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            throw Failure.listenerFailed(String(describing: error))
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        do {
            try await Self.waitUntilReady(listener, on: queue)
        } catch {
            listener.cancel()
            throw error
        }

        self.listener = listener
        boundPort = listener.port?.rawValue ?? requested
        return boundPort ?? requested
    }

    /// Stopping closes every open connection (FR-2) and releases the port.
    public func stop() async {
        let open = connections.values
        connections.removeAll()
        for entry in open {
            // Each connection closes itself: a WebSocket client is told why before its socket goes,
            // and an HTTP connection mid-request is simply cancelled.
            await entry.connection.shutdown()
            entry.task.cancel()
        }
        hub.closeAll(.goingAway, reason: "bridge stopped")
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    // MARK: - Accepting

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let id = UUID()
        let socket = Socket(connection: connection, queue: queue)
        let bridgeConnection = BridgeConnection(
            socket: socket,
            handler: handler,
            hub: hub,
            pingInterval: pingInterval
        )
        let task = Task {
            await bridgeConnection.run()
            self.finished(id)
        }
        connections[id] = Connection(task: task, socket: socket, connection: bridgeConnection)
    }

    private func finished(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    // MARK: - Readiness

    /// Resolves when the listener is ready, or throws with why it is not.
    ///
    /// `nonisolated` and `static` so it holds nothing of the actor while it waits: binding a port
    /// can raise the macOS local-network prompt, and that can take as long as a person takes.
    private static func waitUntilReady(_ listener: NWListener, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state {
                    case .ready, .failed, .cancelled:
                        done = true
                        return true
                    case .setup, .waiting:
                        return false
                    @unknown default:
                        return false
                    }
                }
                guard shouldResume else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: Failure.listenerFailed(String(describing: error)))
                default:
                    continuation.resume(throwing: Failure.listenerFailed("cancelled"))
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
    }
}
