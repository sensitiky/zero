import Foundation
import Testing

@testable import ZeroBridge

/// FR-1 and the input bounds.
///
/// The parser is fed the way a socket feeds it: in whatever chunks arrive. Every test here that
/// splits a request is a test that this does not quietly depend on one read being one request.
@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {

    private func parse(_ chunks: [String]) throws -> HTTPRequest? {
        var parser = HTTPRequestParser()
        var request: HTTPRequest?
        for chunk in chunks {
            parser.append(Data(chunk.utf8))
            if request == nil { request = try parser.nextRequest() }
        }
        return request
    }

    @Test("a whole request in one chunk")
    func wholeRequest() throws {
        let request = try #require(
            try parse(["GET /api/sessions HTTP/1.1\r\nHost: mac.local\r\n\r\n"])
        )
        #expect(request.method == "GET")
        #expect(request.path == "/api/sessions")
        #expect(request.version == "HTTP/1.1")
        #expect(request.headers["host"] == "mac.local")
        #expect(request.body.isEmpty)
    }

    @Test("the same request split at every byte boundary parses identically")
    func splitAtEveryBoundary() throws {
        let raw = "POST /api/sessions/abc/messages HTTP/1.1\r\nHost: mac.local\r\n"
            + "X-Zero-Pair: 418205\r\nContent-Length: 17\r\n\r\n{\"text\":\"hello\"}\n"
        let bytes = Array(raw.utf8)
        for split in 1..<bytes.count {
            var parser = HTTPRequestParser()
            parser.append(Data(bytes[0..<split]))
            var request = try parser.nextRequest()
            if request == nil {
                parser.append(Data(bytes[split...]))
                request = try parser.nextRequest()
            } else {
                // A complete request came out of the first half, which can only happen if the split
                // is past the body — feed the rest so nothing is lost.
                parser.append(Data(bytes[split...]))
            }
            let parsed = try #require(request, "no request at split \(split)")
            #expect(parsed.method == "POST")
            #expect(parsed.path == "/api/sessions/abc/messages")
            #expect(parsed.headers["x-zero-pair"] == "418205")
            #expect(String(data: parsed.body, encoding: .utf8) == "{\"text\":\"hello\"}\n")
        }
    }

    @Test("header names are case-insensitive in both directions")
    func headerCase() throws {
        let request = try #require(
            try parse(["GET /api/health HTTP/1.1\r\nX-ZERO-PAIR: 000123\r\n\r\n"])
        )
        #expect(request.headers["x-zero-pair"] == "000123")
        #expect(request.headers["X-Zero-Pair"] == "000123")
        #expect(request.headers["x-ZeRo-PaIr"] == "000123")
    }

    @Test("a repeated header is joined, not silently overwritten")
    func repeatedHeader() throws {
        let request = try #require(
            try parse(["GET / HTTP/1.1\r\nAccept: a\r\nAccept: b\r\n\r\n"])
        )
        #expect(request.headers["accept"] == "a, b")
    }

    @Test("Connection lists a token case-insensitively")
    func connectionLists() throws {
        let request = try #require(
            try parse(["GET / HTTP/1.1\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n"])
        )
        #expect(request.headers.lists("upgrade", in: "connection"))
        #expect(request.headers.lists("KEEP-ALIVE", in: "connection"))
        #expect(!request.headers.lists("close", in: "connection"))
    }

    @Test("query parameters carry the pairing code a WebSocket cannot put in a header")
    func queryParameters() throws {
        let request = try #require(
            try parse(["GET /api/sessions/abc/events?pair=418205&x=a%20b HTTP/1.1\r\n\r\n"])
        )
        #expect(request.path == "/api/sessions/abc/events")
        #expect(request.query["pair"] == "418205")
        #expect(request.query["x"] == "a b")
    }

    @Test("two requests in one read both come out, in order")
    func pipelined() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8))
        #expect(try parser.nextRequest()?.path == "/a")
        #expect(try parser.nextRequest()?.path == "/b")
        #expect(try parser.nextRequest() == nil)
    }

    @Test("bytes after the upgrade request survive the handoff to frame mode")
    func remainder() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /api/events HTTP/1.1\r\n\r\n".utf8))
        parser.append(Data([0x81, 0x80, 0x00, 0x00, 0x00, 0x00]))
        _ = try parser.nextRequest()
        #expect(parser.hasBufferedBytes)
        #expect(parser.takeRemainder() == Data([0x81, 0x80, 0x00, 0x00, 0x00, 0x00]))
        #expect(!parser.hasBufferedBytes)
    }

    @Test("a body is withheld until all of it has arrived")
    func partialBody() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8))
        #expect(try parser.nextRequest() == nil)
        parser.append(Data("cd".utf8))
        #expect(String(data: try #require(try parser.nextRequest()).body, encoding: .utf8) == "abcd")
    }

    // MARK: - Caps and malformed input

    @Test("a Content-Length over the cap throws before anything is allocated for it")
    func bodyOverCap() {
        var parser = HTTPRequestParser()
        let claimed = BridgeLimits.body + 1
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: \(claimed)\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.bodyTooLarge) { try parser.nextRequest() }
        #expect(HTTPRequestParser.Failure.bodyTooLarge.bridgeError.status == 413)
    }

    @Test("a request line over the cap is rejected before the head is complete")
    func requestLineOverCap() {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /\(String(repeating: "a", count: BridgeLimits.requestLine + 8))".utf8))
        #expect(throws: HTTPRequestParser.Failure.requestLineTooLong) { try parser.nextRequest() }
    }

    @Test("a header block that never ends is bounded")
    func headerBlockOverCap() {
        var parser = HTTPRequestParser()
        parser.append(Data("GET / HTTP/1.1\r\n".utf8))
        let filler = "X-Pad: \(String(repeating: "a", count: 1000))\r\n"
        for _ in 0..<((BridgeLimits.headerBlock / 1000) + 10) {
            parser.append(Data(filler.utf8))
        }
        #expect(throws: HTTPRequestParser.Failure.headerBlockTooLarge) { try parser.nextRequest() }
    }

    @Test("a malformed request line is a 400, not a guess")
    func malformedRequestLine() {
        var parser = HTTPRequestParser()
        parser.append(Data("NOT-A-REQUEST\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.malformedRequestLine) { try parser.nextRequest() }
        #expect(HTTPRequestParser.Failure.malformedRequestLine.bridgeError.status == 400)
    }

    @Test("a header without a colon is malformed")
    func malformedHeader() {
        var parser = HTTPRequestParser()
        parser.append(Data("GET / HTTP/1.1\r\nnonsense\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.malformedHeader) { try parser.nextRequest() }
    }

    @Test("a non-numeric Content-Length is malformed")
    func malformedContentLength() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: many\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.malformedContentLength) {
            try parser.nextRequest()
        }
    }

    @Test("chunked transfer encoding is refused rather than half-supported")
    func chunkedRefused() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.unsupportedTransferEncoding) {
            try parser.nextRequest()
        }
    }

    @Test("keep-alive follows the version and the Connection header")
    func keepAlive() throws {
        let http11 = try #require(try parse(["GET / HTTP/1.1\r\n\r\n"]))
        #expect(http11.wantsKeepAlive)
        let closing = try #require(try parse(["GET / HTTP/1.1\r\nConnection: close\r\n\r\n"]))
        #expect(!closing.wantsKeepAlive)
        let http10 = try #require(try parse(["GET / HTTP/1.0\r\n\r\n"]))
        #expect(!http10.wantsKeepAlive)
        let http10KeepAlive = try #require(
            try parse(["GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"])
        )
        #expect(http10KeepAlive.wantsKeepAlive)
    }
}
