import Foundation

/// The frame opcodes this server understands. Anything else is a protocol error and a close, not a
/// frame to guess at.
public enum WebSocketOpcode: UInt8, Sendable, Equatable, CaseIterable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    /// Control frames are never fragmented and carry at most 125 bytes (RFC 6455 §5.5).
    public var isControl: Bool { rawValue & 0x8 != 0 }
}

/// RFC 6455 close codes this server sends.
public enum WebSocketCloseCode: UInt16, Sendable, Equatable {
    case normal = 1000
    case goingAway = 1001
    case protocolError = 1002
    case messageTooBig = 1009
    /// Wrong or missing pairing code (FR-4), and an unknown session id.
    case policyViolation = 1008
    /// A client too slow to drain its queue (bounded memory).
    case tryAgainLater = 1013
}

/// One frame. A value: the decoder hands out completed frames only, so nothing downstream can be
/// given a half-read one.
public struct WebSocketFrame: Sendable, Equatable {
    public var isFinal: Bool
    public var opcode: WebSocketOpcode
    public var payload: Data

    public init(isFinal: Bool = true, opcode: WebSocketOpcode, payload: Data = Data()) {
        self.isFinal = isFinal
        self.opcode = opcode
        self.payload = payload
    }

    public static func text(_ string: String) -> WebSocketFrame {
        WebSocketFrame(opcode: .text, payload: Data(string.utf8))
    }

    public static func ping(_ payload: Data = Data()) -> WebSocketFrame {
        WebSocketFrame(opcode: .ping, payload: payload)
    }

    public static func pong(_ payload: Data = Data()) -> WebSocketFrame {
        WebSocketFrame(opcode: .pong, payload: payload)
    }

    /// A close frame. The reason is truncated to fit the 125-byte control limit — a close that is
    /// itself a protocol error is not a close.
    public static func close(_ code: WebSocketCloseCode, reason: String = "") -> WebSocketFrame {
        var payload = Data([UInt8(code.rawValue >> 8), UInt8(code.rawValue & 0xFF)])
        var reasonBytes = Array(reason.utf8)
        if reasonBytes.count > 123 { reasonBytes = Array(reasonBytes.prefix(123)) }
        payload.append(contentsOf: reasonBytes)
        return WebSocketFrame(opcode: .close, payload: payload)
    }

    /// The close code a peer sent, if its close frame carried one.
    public var closeCode: UInt16? {
        guard opcode == .close, payload.count >= 2 else { return nil }
        let bytes = Array(payload)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    /// The frame as bytes. Server frames are never masked (RFC 6455 §5.1), which is also why the
    /// encoder takes no key: there is no code path here that could mask one by accident.
    public func encoded() -> Data {
        var bytes: [UInt8] = []
        bytes.append((isFinal ? 0x80 : 0x00) | opcode.rawValue)
        let length = payload.count
        if length < 126 {
            bytes.append(UInt8(length))
        } else if length <= 0xFFFF {
            bytes.append(126)
            bytes.append(UInt8((length >> 8) & 0xFF))
            bytes.append(UInt8(length & 0xFF))
        } else {
            bytes.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((length >> shift) & 0xFF))
            }
        }
        var data = Data(bytes)
        data.append(payload)
        return data
    }
}

/// An incremental frame decoder.
///
/// Fed arbitrary chunk boundaries, like `HTTPRequestParser`, and for the same reason: a decoder that
/// assumes one read is one frame works on localhost and fails on a phone.
///
/// **No force-unwraps, and no allocation on a claimed length.** A frame whose length field says more
/// than the cap throws before a byte is reserved for it — that field is the one number an attacker
/// fully controls.
public struct WebSocketFrameDecoder: Sendable {

    public enum Failure: Error, Sendable, Equatable {
        case reservedBitsSet
        case unknownOpcode(UInt8)
        /// A client frame must be masked (RFC 6455 §5.1). A server that accepts an unmasked one is
        /// a server that can be driven by a cross-protocol request from a browser.
        case unmaskedClientFrame
        case controlFrameTooLarge
        case fragmentedControlFrame
        case frameTooLarge

        public var closeCode: WebSocketCloseCode {
            switch self {
            case .frameTooLarge, .controlFrameTooLarge: .messageTooBig
            case .reservedBitsSet, .unknownOpcode, .unmaskedClientFrame, .fragmentedControlFrame:
                .protocolError
            }
        }
    }

    private var buffer: [UInt8] = []

    /// A client frame must be masked and a server frame must not be (RFC 6455 §5.1). The server
    /// always decodes with this on; it is off only for a decoder reading *server* frames, which is
    /// what a test client is.
    private let expectsMaskedFrames: Bool

    public init(expectsMaskedFrames: Bool = true) {
        self.expectsMaskedFrames = expectsMaskedFrames
    }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    /// The next complete frame, or nil if more bytes are needed.
    public mutating func nextFrame() throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let first = buffer[0]
        guard first & 0x70 == 0 else { throw Failure.reservedBitsSet }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw Failure.unknownOpcode(first & 0x0F)
        }
        let isFinal = first & 0x80 != 0

        let second = buffer[1]
        let isMasked = second & 0x80 != 0
        let short = Int(second & 0x7F)

        var cursor = 2
        var length = short
        if short == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            length = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
            cursor += 2
        } else if short == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            // The top bit must be zero (RFC 6455), and anything that large is over the cap anyway —
            // accumulate in `UInt64` so the shift cannot trap on a 64-bit `Int`.
            var wide: UInt64 = 0
            for index in cursor..<(cursor + 8) {
                wide = wide << 8 | UInt64(buffer[index])
            }
            guard wide <= UInt64(BridgeLimits.frame) else { throw Failure.frameTooLarge }
            length = Int(wide)
            cursor += 8
        }

        if opcode.isControl {
            guard length <= 125 else { throw Failure.controlFrameTooLarge }
            guard isFinal else { throw Failure.fragmentedControlFrame }
        }
        // Thrown from the length field, before a byte of the payload is buffered for.
        guard length <= BridgeLimits.frame else { throw Failure.frameTooLarge }
        if expectsMaskedFrames {
            guard isMasked else { throw Failure.unmaskedClientFrame }
        }

        var mask: [UInt8] = [0, 0, 0, 0]
        if isMasked {
            guard buffer.count >= cursor + 4 else { return nil }
            mask = Array(buffer[cursor..<(cursor + 4)])
            cursor += 4
        }

        guard buffer.count >= cursor + length else { return nil }
        var payload = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            payload[index] = buffer[cursor + index] ^ mask[index % 4]
        }
        buffer.removeFirst(cursor + length)

        return WebSocketFrame(isFinal: isFinal, opcode: opcode, payload: Data(payload))
    }
}

/// Reassembles fragmented data frames into whole messages, with the cap applied to the **total**.
///
/// Separate from the decoder because a control frame may arrive between two fragments — a ping in
/// the middle of a long message is legal and must be answered — so the two concerns cannot be one
/// loop without the cap being applied to the wrong number.
public struct WebSocketMessageAssembler: Sendable {

    public enum Failure: Error, Sendable, Equatable {
        case unexpectedContinuation
        case interleavedDataFrame
        case messageTooLarge

        public var closeCode: WebSocketCloseCode {
            switch self {
            case .messageTooLarge: .messageTooBig
            case .unexpectedContinuation, .interleavedDataFrame: .protocolError
            }
        }
    }

    public struct Message: Sendable, Equatable {
        /// `.text` or `.binary` — the opcode of the first fragment.
        public var opcode: WebSocketOpcode
        public var payload: Data

        public var text: String? { String(data: payload, encoding: .utf8) }
    }

    private var openOpcode: WebSocketOpcode?
    private var buffer = Data()

    public init() {}

    /// A control frame passes straight through as its own message; a data frame is assembled.
    /// Returns nil while a message is still incomplete.
    public mutating func accept(_ frame: WebSocketFrame) throws -> Message? {
        if frame.opcode.isControl {
            return Message(opcode: frame.opcode, payload: frame.payload)
        }

        switch frame.opcode {
        case .continuation:
            guard let opcode = openOpcode else { throw Failure.unexpectedContinuation }
            try grow(with: frame.payload)
            guard frame.isFinal else { return nil }
            let message = Message(opcode: opcode, payload: buffer)
            reset()
            return message

        case .text, .binary:
            guard openOpcode == nil else { throw Failure.interleavedDataFrame }
            if frame.isFinal {
                guard frame.payload.count <= BridgeLimits.frame else {
                    throw Failure.messageTooLarge
                }
                return Message(opcode: frame.opcode, payload: frame.payload)
            }
            openOpcode = frame.opcode
            buffer = Data()
            try grow(with: frame.payload)
            return nil

        case .close, .ping, .pong:
            // Unreachable: handled above by `isControl`. Written out rather than defaulted so a new
            // opcode has to be considered here too.
            return Message(opcode: frame.opcode, payload: frame.payload)
        }
    }

    private mutating func grow(with payload: Data) throws {
        guard buffer.count + payload.count <= BridgeLimits.frame else {
            reset()
            throw Failure.messageTooLarge
        }
        buffer.append(payload)
    }

    private mutating func reset() {
        openOpcode = nil
        buffer = Data()
    }
}
