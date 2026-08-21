import Foundation

/// Reassembles newline-delimited records from arbitrary byte chunks.
///
/// Every provider protocol Zero speaks is NDJSON over a pipe, and pipe chunks land wherever the
/// kernel decides — routinely mid-record. Getting this wrong fails silently, which is why it is
/// isolated here as a pure value type instead of living inside the read loop.
public struct LineAccumulator: Sendable {
    public struct OversizeLine: Error, Sendable {
        public let bytes: Int
        public let limit: Int
    }

    public let maxLineBytes: Int
    private var buffer: [UInt8] = []

    public init(maxLineBytes: Int = 64 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Feeds a chunk and returns the records it completed, in order.
    ///
    /// Empty lines are dropped — no provider protocol assigns them meaning. A record larger than
    /// `maxLineBytes` throws and clears the buffer: a runaway line means the stream is no longer
    /// trustworthy, and buffering it to exhaustion is worse than failing.
    public mutating func append(_ chunk: some Sequence<UInt8>) throws -> [Data] {
        var records: [Data] = []
        for byte in chunk {
            guard byte != UInt8(ascii: "\n") else {
                let record = Self.take(&buffer)
                if !record.isEmpty { records.append(record) }
                continue
            }
            buffer.append(byte)
            if buffer.count > maxLineBytes {
                let overflow = buffer.count
                buffer = []
                throw OversizeLine(bytes: overflow, limit: maxLineBytes)
            }
        }
        return records
    }

    /// The trailing record when the stream ends without a final newline.
    public mutating func flush() -> Data? {
        let record = Self.take(&buffer)
        return record.isEmpty ? nil : record
    }

    private static func take(_ buffer: inout [UInt8]) -> Data {
        var bytes = buffer
        buffer.removeAll(keepingCapacity: true)
        if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
        return Data(bytes)
    }
}
