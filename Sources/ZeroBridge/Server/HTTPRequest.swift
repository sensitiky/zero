import Foundation

/// Header names are case-insensitive (RFC 9110), and treating them otherwise is the bug that makes
/// one HTTP client work and the next one not.
public struct HTTPHeaders: Sendable, Equatable {
    private var storage: [String: String] = [:]

    public init() {}

    public init(_ pairs: [(String, String)]) {
        for (name, value) in pairs { self[name] = value }
    }

    public subscript(name: String) -> String? {
        get { storage[name.lowercased()] }
        set { storage[name.lowercased()] = newValue }
    }

    /// Whether a comma-separated header lists a token, case-insensitively — the shape `Connection`
    /// and `Upgrade` both use.
    public func lists(_ token: String, in name: String) -> Bool {
        guard let value = self[name] else { return false }
        return value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == token.lowercased()
        }
    }
}

/// One parsed request. A value, so nothing downstream can be handed a half-read connection.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The raw request target, query string included.
    public var target: String
    public var version: String
    public var headers: HTTPHeaders
    public var body: Data

    public init(
        method: String,
        target: String,
        version: String = "HTTP/1.1",
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data()
    ) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }

    /// The path, percent-decoded, without the query.
    public var path: String {
        let raw = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return raw.removingPercentEncoding ?? raw
    }

    /// Query parameters, percent-decoded. This is how the pairing code arrives on a WebSocket:
    /// React Native cannot set WebSocket headers portably (FR-4).
    public var query: [String: String] {
        guard let raw = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first, !name.isEmpty else { continue }
            let key = String(name).replacingOccurrences(of: "+", with: " ")
            let value = parts.dropFirst().first.map(String.init) ?? ""
            result[key.removingPercentEncoding ?? key] =
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return result
    }

    /// Whether the client asked to keep the connection open. HTTP/1.1 keeps it by default;
    /// `Connection: close` is honoured.
    public var wantsKeepAlive: Bool {
        if headers.lists("close", in: "connection") { return false }
        if headers.lists("keep-alive", in: "connection") { return true }
        return version == "HTTP/1.1"
    }
}
