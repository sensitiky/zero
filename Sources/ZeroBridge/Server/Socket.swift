import Foundation
import Network
import Synchronization

/// `NWConnection` with an `async` face.
///
/// Everything here runs on the bridge's own `DispatchQueue`, never the main one (FR-6): accept,
/// read, write and every callback in between. The main actor is reached only by the adapter, and
/// only with `Sendable` values.
///
/// Each continuation is resumed exactly once — the receive and send callbacks fire once by
/// contract, and the state handler is guarded by a flag because it does not.
final class Socket: @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Start the connection and wait for it to be usable.
    func start() async throws {
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state {
                    case .ready, .failed, .cancelled:
                        done = true
                        return true
                    case .setup, .preparing, .waiting:
                        return false
                    @unknown default:
                        return false
                    }
                }
                guard shouldResume else { return }
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: SocketError.closed)
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    /// The next bytes, or nil at end of stream. An empty `Data` means "nothing yet, keep reading".
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    enum SocketError: Error, Sendable, Equatable {
        case closed
    }
}
