import Foundation

/// A response, and the bytes it becomes.
///
/// `Content-Length` is always written — never a chunked or a connection-delimited body, so a
/// keep-alive connection stays parseable for the request after this one.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// Whether the connection closes after this response. Set for every error, and for a request
    /// that asked for `Connection: close`.
    public var closeConnection: Bool

    public init(
        status: Int,
        headers: [(name: String, value: String)] = [],
        body: Data = Data(),
        closeConnection: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.closeConnection = closeConnection
    }

    public static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status
            && lhs.body == rhs.body
            && lhs.closeConnection == rhs.closeConnection
            && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
    }

    /// A JSON response. Every response in the contract is one of these, except `204`.
    public static func json(status: Int, body: Data, closeConnection: Bool = false) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [(name: "Content-Type", value: "application/json; charset=utf-8")],
            body: body,
            closeConnection: closeConnection
        )
    }

    public static func json(
    status: Int,
    _ value: some Encodable,
    closeConnection: Bool = false
    ) -> HTTPResponse {
    do {
        return json(
            status: status,
            body: try BridgeJSON.encode(value),
            closeConnection: closeConnection
        )
    } catch {
        // Encoding a DTO cannot realistically fail, and if it does the client still gets the
        // contract's shape rather than a truncated body or a dropped connection. The message is
        // fixed text: `error` here could hold anything, and anything is not safe to echo.
        return HTTPResponse.error(
            .internalFailure("Response could not be encoded.")
            )
        }
    }

    /// The contract's error body, with the contract's status. Always closes: a connection that just
    /// failed to be understood is not a connection to keep reading from.
    public static func error(_ error: BridgeError) -> HTTPResponse {
        let body = (try? BridgeJSON.encode(error.body))
            ?? Data(#"{"error":"internal","message":"Error could not be encoded."}"#.utf8)
        return json(status: error.status, body: body, closeConnection: true)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for header in headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        // 101 has switched protocols: there is no body and no length to declare, and its own
        // `Connection: Upgrade` is already in `headers` — writing a second `Connection` here is how
        // a handshake that looks right on the wire gets rejected by a strict client.
        if status == 101 {
            head += "\r\n"
        } else {
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: \(closeConnection ? "close" : "keep-alive")\r\n\r\n"
        }
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// The reason phrase is advisory in HTTP/1.1, but a wrong one reads as a broken server in
    /// every log and every proxy.
    static func reason(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 426: "Upgrade Required"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
