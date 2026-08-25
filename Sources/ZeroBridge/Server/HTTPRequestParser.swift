import Foundation

/// An incremental HTTP/1.1 request parser.
///
/// Incremental because bytes arrive in whatever chunks the network gives us, and a parser that
/// assumes one read is one request works on localhost and fails on a phone. It is fed arbitrary
/// chunk boundaries — a request split mid-header, two requests in one read, a body arriving in
/// pieces — and produces requests only when they are complete.
///
/// **No force-unwraps.** Every index into the buffer is bounds-checked, every integer comes from a
/// validated parse, and a length field that claims more than the cap throws before anything is
/// allocated for it.
public struct HTTPRequestParser: Sendable {

    /// What can go wrong, typed, so the caller turns it into the contract's status and a close
    /// rather than guessing.
    public enum Failure: Error, Sendable, Equatable {
        case requestLineTooLong
        case headerBlockTooLarge
        case bodyTooLarge
        case malformedRequestLine
        case malformedHeader
        case malformedContentLength
        /// Chunked bodies are not supported: the contract's bodies are small JSON objects, and a
        /// chunked decoder is a second parser to get wrong for a case no client here produces.
        case unsupportedTransferEncoding

        /// The response the contract gives for this failure.
        public var bridgeError: BridgeError {
            switch self {
            case .bodyTooLarge: .tooLarge
            case .requestLineTooLong, .headerBlockTooLarge: .tooLarge
            case .malformedRequestLine, .malformedHeader, .malformedContentLength,
                 .unsupportedTransferEncoding:
                .badRequest("Malformed request.")
            }
        }
    }

    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Whatever is left unparsed, taken out of the parser.
    ///
    /// This is the handoff to frame mode: a client that pipelines its first WebSocket frame behind
    /// the upgrade request has those bytes sitting here, and dropping them loses the frame.
    public mutating func takeRemainder() -> Data {
        let remainder = Data(buffer)
        buffer.removeAll()
        return remainder
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    /// The next complete request, or nil if more bytes are needed.
    public mutating func nextRequest() throws -> HTTPRequest? {
        guard let head = try headBoundaries() else { return nil }

        guard let requestLine = string(from: head.lines[0]) else {
            throw Failure.malformedRequestLine
        }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw Failure.malformedRequestLine
        }

        var headers = HTTPHeaders()
        for range in head.lines.dropFirst() {
            guard let line = string(from: range) else { throw Failure.malformedHeader }
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformedHeader }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw Failure.malformedHeader }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated header is joined with a comma, per RFC 9110 §5.2, rather than the last one
            // silently winning.
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if let encoding = headers["transfer-encoding"], !encoding.isEmpty {
            throw Failure.unsupportedTransferEncoding
        }

        var length = 0
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                throw Failure.malformedContentLength
            }
            // Thrown from the length field, before a byte of it is buffered for.
            guard parsed <= BridgeLimits.body else { throw Failure.bodyTooLarge }
            length = parsed
        }

        guard buffer.count >= head.bodyStart + length else { return nil }
        let body = Data(buffer[head.bodyStart..<(head.bodyStart + length)])
        buffer.removeFirst(head.bodyStart + length)

        return HTTPRequest(
            method: parts[0],
            target: parts[1],
            version: parts[2],
            headers: headers,
            body: body
        )
    }

    // MARK: - Head scanning

    private struct Head {
        var lines: [Range<Int>]
        var bodyStart: Int
    }

    /// Splits the head into lines, or reports that more bytes are needed — throwing first if the
    /// buffer has already grown past what a head is allowed to be.
    ///
    /// Lenient about line endings: `\r\n` and a bare `\n` both terminate a line. Being strict here
    /// buys nothing and rejects hand-typed requests, which is how this gets debugged.
    private func headBoundaries() throws -> Head? {
        var lines: [Range<Int>] = []
        var cursor = 0
        while let newline = buffer[cursor...].firstIndex(of: Self.lf) {
            var end = newline
            if end > cursor, buffer[end - 1] == Self.cr { end -= 1 }
            if end == cursor {
                guard let first = lines.first else { throw Failure.malformedRequestLine }
                guard first.count <= BridgeLimits.requestLine else {
                    throw Failure.requestLineTooLong
                }
                guard newline + 1 - first.upperBound <= BridgeLimits.headerBlock else {
                    throw Failure.headerBlockTooLarge
                }
                return Head(lines: lines, bodyStart: newline + 1)
            }
            lines.append(cursor..<end)
            cursor = newline + 1
            if lines.count == 1, lines[0].count > BridgeLimits.requestLine {
                throw Failure.requestLineTooLong
            }
        }
        // Incomplete head. Bound it by what has arrived so far, so a client that never sends the
        // blank line cannot make us buffer forever.
        if lines.isEmpty, buffer.count > BridgeLimits.requestLine {
            throw Failure.requestLineTooLong
        }
        if buffer.count > BridgeLimits.requestLine + BridgeLimits.headerBlock {
            throw Failure.headerBlockTooLarge
        }
        return nil
    }

    private func string(from range: Range<Int>) -> String? {
        String(data: Data(buffer[range]), encoding: .utf8)
    }
}
