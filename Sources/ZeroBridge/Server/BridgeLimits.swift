import Foundation

/// Every cap in one place, because "bounded input" is only true if the bounds are findable.
///
/// A server on a LAN is still a server: a malformed request must close the connection rather than
/// allocate what its length field claims, and a phone that went to sleep must not be able to grow a
/// send queue until the Mac runs out of memory.
public enum BridgeLimits {
    /// Request line, so a path cannot be unbounded.
    public static let requestLine = 8 * 1024
    /// The whole header block after the request line.
    public static let headerBlock = 32 * 1024
    /// Request body (CONTRACT.md: 1 MiB).
    public static let body = 1024 * 1024
    /// One WebSocket message, assembled fragments included.
    public static let frame = 1024 * 1024
    /// Frames queued for one client before it is dropped with `1013`.
    public static let sendQueue = 256
    /// How often the server pings (FR-25).
    public static let pingInterval: Duration = .seconds(30)
    /// The default port. Configurable — see FR-3.
    public static let defaultPort: UInt16 = 4000
}
