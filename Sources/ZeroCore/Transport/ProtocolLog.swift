import Foundation

/// Logs raw NDJSON wire traffic for debugging adapters.
///
/// Off by default. When enabled, records both inbound (from provider) and outbound
/// (to provider) records in order. Credentials are redacted before writing to disk.
/// Logging does not block the caller; writes happen on a background queue.
public actor ProtocolLog: Sendable {
    /// Direction of a record on the wire.
    public enum Direction: String, Sendable, Codable {
        case inbound
        case outbound
    }

    /// One record written to the log.
    public struct Record: Sendable, Codable {
        public let timestamp: Date
        public let direction: Direction
        public let data: String // JSON string, redacted
    }

    private let logURL: URL
    private let maxSizeBytes: Int
    private let redactor: Redactor
    private let writeQueue = DispatchQueue(
        label: "the.stool.zero.protocol-log",
        qos: .background
    )
    private var isEnabled: Bool = false

    /// Creates a protocol log that writes to the given file.
    ///
    /// - Parameters:
    ///   - logURL: File path where records will be written. Parent directory must exist.
    ///   - maxSizeBytes: Maximum file size before rotation. Default: 10 MB.
    public init(
        logURL: URL,
        maxSizeBytes: Int = 10 << 20,
        redactor: Redactor = Redactor()
    ) {
        self.logURL = logURL
        self.maxSizeBytes = maxSizeBytes
        self.redactor = redactor
    }

    /// Enables protocol logging. All subsequent records will be written.
    public func enable() {
        isEnabled = true
    }

    /// Disables protocol logging. In-flight writes complete, but no new records are accepted.
    public func disable() {
        isEnabled = false
    }

    /// Records an inbound record (from the provider).
    /// The record is redacted before writing. Logging is non-blocking.
    public func logInbound(_ data: Data) {
        guard isEnabled else { return }
        log(data: data, direction: .inbound)
    }

    /// Records an outbound record (to the provider).
    /// The record is redacted before writing. Logging is non-blocking.
    public func logOutbound(_ data: Data) {
        guard isEnabled else { return }
        log(data: data, direction: .outbound)
    }

    // MARK: - Private

    private func log(data: Data, direction: Direction) {
        let record = data
        let redacted = redactor.redact(record)
        let stringData = String(decoding: redacted, as: UTF8.self)
        let logURL = self.logURL
        let maxSize = self.maxSizeBytes

        writeQueue.async {
            Self.writeRecord(
                timestamp: Date(),
                direction: direction,
                data: stringData,
                to: logURL,
                maxSizeBytes: maxSize
            )
        }
    }

    nonisolated private static func writeRecord(
        timestamp: Date,
        direction: Direction,
        data: String,
        to logURL: URL,
        maxSizeBytes: Int
    ) {
        let record = Record(timestamp: timestamp, direction: direction, data: data)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(record)

            let fm = FileManager.default
            let exists = fm.fileExists(atPath: logURL.path)

            // Rotate if needed.
            if exists {
                let attrs = try fm.attributesOfItem(atPath: logURL.path)
                if let size = attrs[.size] as? Int, size > maxSizeBytes {
                    Self.rotate(logURL)
                }
            }

            // Append the record.
            var payload = jsonData
            payload.append(UInt8(ascii: "\n"))

            if !exists {
                try payload.write(to: logURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try handle.write(contentsOf: payload)
            }
        } catch {
            // Silently drop write failures; logging should never break the app.
        }
    }

    nonisolated private static func rotate(_ logURL: URL) {
        do {
            let fm = FileManager.default
            let backup = logURL.appendingPathExtension("1")

            // Shift existing backups.
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: backup)
            }

            if fm.fileExists(atPath: logURL.path) {
                try fm.moveItem(at: logURL, to: backup)
            }
        } catch {
            // Silently drop rotation failures.
        }
    }
}

/// Redacts secrets from wire records before they are written to disk.
public struct Redactor: Sendable {
    public init() {}

    /// Redacts secrets from raw data. Returns data with credentials replaced by placeholders.
    public func redact(_ data: Data) -> Data {
        guard var stringData = String(data: data, encoding: .utf8) else {
            return data
        }

        // API keys: "api_key":"sk-xxx" or similar
        stringData = redact(stringData, pattern: "\"api[_-]?key\"\\s*:\\s*\"[^\"]+\"", replacement: "\"api_key\":\"<redacted>\"")
        stringData = redact(stringData, pattern: "\"apiKey\"\\s*:\\s*\"[^\"]+\"", replacement: "\"apiKey\":\"<redacted>\"")

        // Bearer tokens: "Authorization":"Bearer xxx"
        stringData = redact(stringData, pattern: "\"Authorization\"\\s*:\\s*\"Bearer\\s+[^\"]+\"", replacement: "\"Authorization\":\"Bearer <redacted>\"")
        stringData = redact(stringData, pattern: "\"authorization\"\\s*:\\s*\"Bearer\\s+[^\"]+\"", replacement: "\"authorization\":\"Bearer <redacted>\"")

        // OAuth access and refresh tokens
        stringData = redact(stringData, pattern: "\"access_token\"\\s*:\\s*\"[^\"]+\"", replacement: "\"access_token\":\"<redacted>\"")
        stringData = redact(stringData, pattern: "\"accessToken\"\\s*:\\s*\"[^\"]+\"", replacement: "\"accessToken\":\"<redacted>\"")
        stringData = redact(stringData, pattern: "\"refresh_token\"\\s*:\\s*\"[^\"]+\"", replacement: "\"refresh_token\":\"<redacted>\"")
        stringData = redact(stringData, pattern: "\"refreshToken\"\\s*:\\s*\"[^\"]+\"", replacement: "\"refreshToken\":\"<redacted>\"")

        // Generic token fields
        stringData = redact(stringData, pattern: "\"token\"\\s*:\\s*\"[^\"]+\"", replacement: "\"token\":\"<redacted>\"")
        stringData = redact(stringData, pattern: "\"auth[_-]?token\"\\s*:\\s*\"[^\"]+\"", replacement: "\"auth_token\":\"<redacted>\"")

        // Bare Authorization headers (HTTP form)
        stringData = redact(stringData, pattern: "[Aa]uthorization:\\s*Bearer\\s+[^\\s\\r\\n]+", replacement: "Authorization: Bearer <redacted>")

        return Data(stringData.utf8)
    }

    private func redact(_ string: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return string
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replacement)
    }
}
