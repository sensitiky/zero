import Foundation
import Testing

@testable import ZeroBridge

/// FR-1: masking, fragmentation, oversize.
///
/// The decoder is the one place a remote peer picks the numbers, so most of what is asserted here is
/// what it refuses.
@Suite("WebSocketFrame")
struct WebSocketFrameTests {

    /// A client frame, masked as RFC 6455 requires of a client.
    private func clientFrame(
        opcode: WebSocketOpcode,
        payload: Data,
        isFinal: Bool = true,
        mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
    ) -> Data {
        var bytes: [UInt8] = [(isFinal ? 0x80 : 0x00) | opcode.rawValue]
        let length = payload.count
        if length < 126 {
            bytes.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            bytes.append(0x80 | 126)
            bytes.append(UInt8((length >> 8) & 0xFF))
            bytes.append(UInt8(length & 0xFF))
        } else {
            bytes.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((length >> shift) & 0xFF))
            }
        }
        bytes.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            bytes.append(byte ^ mask[index % 4])
        }
        return Data(bytes)
    }

    private func decodeAll(_ data: Data) throws -> [WebSocketFrame] {
        var decoder = WebSocketFrameDecoder()
        decoder.append(data)
        var frames: [WebSocketFrame] = []
        while let frame = try decoder.nextFrame() { frames.append(frame) }
        return frames
    }

    // MARK: - Decoding client frames

    @Test("the RFC 6455 §5.7 masked example decodes to Hello")
    func rfcMaskedExample() throws {
        let raw = Data([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
        let frames = try decodeAll(raw)
        #expect(frames.count == 1)
        #expect(frames.first?.opcode == .text)
        #expect(frames.first?.isFinal == true)
        #expect(String(data: try #require(frames.first?.payload), encoding: .utf8) == "Hello")
    }

    @Test("every opcode round-trips through mask and unmask")
    func maskingRoundTrip() throws {
        for opcode in WebSocketOpcode.allCases where opcode != .continuation {
            let payload = Data("payload for \(opcode)".utf8)
            let frame = try #require(
                try decodeAll(clientFrame(opcode: opcode, payload: payload)).first
            )
            #expect(frame.opcode == opcode)
            #expect(frame.payload == payload)
        }
    }

    @Test("7-, 16- and 64-bit lengths all decode")
    func lengthForms() throws {
        for length in [0, 5, 125, 126, 1000, 0xFFFF, 0xFFFF + 1, 70_000] {
            let payload = Data(repeating: 0x61, count: length)
            let frame = try #require(
                try decodeAll(clientFrame(opcode: .binary, payload: payload)).first
            )
            #expect(frame.payload.count == length)
            #expect(frame.payload == payload)
        }
    }

    @Test("a frame split at every byte boundary decodes identically")
    func splitDecoding() throws {
        let raw = clientFrame(opcode: .text, payload: Data("a longer message to split".utf8))
        let bytes = Array(raw)
        for split in 1..<bytes.count {
            var decoder = WebSocketFrameDecoder()
            decoder.append(Data(bytes[0..<split]))
            #expect(try decoder.nextFrame() == nil, "frame came out early at split \(split)")
            decoder.append(Data(bytes[split...]))
            let frame = try #require(try decoder.nextFrame(), "no frame at split \(split)")
            #expect(String(data: frame.payload, encoding: .utf8) == "a longer message to split")
        }
    }

    @Test("two frames in one read both come out")
    func pipelinedFrames() throws {
        var raw = clientFrame(opcode: .text, payload: Data("one".utf8))
        raw.append(clientFrame(opcode: .ping, payload: Data()))
        let frames = try decodeAll(raw)
        #expect(frames.map(\.opcode) == [.text, .ping])
    }

    // MARK: - Refusals

    @Test("an unmasked client frame is a protocol error")
    func unmaskedClientFrame() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x81, 0x02, 0x68, 0x69]))
        #expect(throws: WebSocketFrameDecoder.Failure.unmaskedClientFrame) {
            try decoder.nextFrame()
        }
        #expect(WebSocketFrameDecoder.Failure.unmaskedClientFrame.closeCode == .protocolError)
    }

    @Test("reserved bits are a protocol error, not an extension we quietly accept")
    func reservedBits() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0xC1, 0x80, 0, 0, 0, 0]))
        #expect(throws: WebSocketFrameDecoder.Failure.reservedBitsSet) { try decoder.nextFrame() }
    }

    @Test("an unknown opcode is a protocol error")
    func unknownOpcode() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x83, 0x80, 0, 0, 0, 0]))
        #expect(throws: WebSocketFrameDecoder.Failure.unknownOpcode(0x3)) { try decoder.nextFrame() }
    }

    @Test("a control frame over 125 bytes, or fragmented, is refused")
    func controlFrameRules() {
        var oversize = WebSocketFrameDecoder()
        oversize.append(clientFrame(opcode: .ping, payload: Data(repeating: 0x61, count: 200)))
        #expect(throws: WebSocketFrameDecoder.Failure.controlFrameTooLarge) {
            try oversize.nextFrame()
        }

        var fragmented = WebSocketFrameDecoder()
        fragmented.append(clientFrame(opcode: .ping, payload: Data("x".utf8), isFinal: false))
        #expect(throws: WebSocketFrameDecoder.Failure.fragmentedControlFrame) {
            try fragmented.nextFrame()
        }
    }

    @Test("a length field over the cap throws before the payload is allocated for")
    func oversizeLengthField() {
        // Only the 10-byte header is fed. If the decoder waited for the payload before checking the
        // cap, this would return nil and a peer could make us buffer as much as it liked.
        var decoder = WebSocketFrameDecoder()
        let claimed = UInt64(BridgeLimits.frame) + 1
        var header: [UInt8] = [0x82, 0x80 | 127]
        for shift in stride(from: 56, through: 0, by: -8) {
            header.append(UInt8((claimed >> UInt64(shift)) & 0xFF))
        }
        decoder.append(Data(header))
        #expect(throws: WebSocketFrameDecoder.Failure.frameTooLarge) { try decoder.nextFrame() }
        #expect(WebSocketFrameDecoder.Failure.frameTooLarge.closeCode == .messageTooBig)
    }

    @Test("a 64-bit length with the top bit set does not trap")
    func hugeLengthDoesNotTrap() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x82, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: WebSocketFrameDecoder.Failure.frameTooLarge) { try decoder.nextFrame() }
    }

    // MARK: - Encoding server frames

    @Test("server frames are never masked, and declare their length three ways")
    func serverEncoding() throws {
        let short = WebSocketFrame.text("Hello").encoded()
        #expect(Array(short.prefix(2)) == [0x81, 0x05])
        #expect(short.count == 7)

        let medium = WebSocketFrame(
            opcode: .text, payload: Data(repeating: 0x61, count: 300)
        ).encoded()
        #expect(Array(medium.prefix(4)) == [0x81, 126, 0x01, 0x2C])
        #expect(medium.count == 304)

        let long = WebSocketFrame(
            opcode: .binary, payload: Data(repeating: 0x61, count: 70_000)
        ).encoded()
        #expect(Array(long.prefix(2)) == [0x82, 127])
        #expect(long.count == 70_010)

        // Bit 0x80 of the second byte is the mask bit. A server that sets it is a server no client
        // will talk to.
        for encoded in [short, medium, long] {
            #expect(encoded[1] & 0x80 == 0)
        }
    }

    @Test("a close frame carries its code, and a long reason is trimmed to fit")
    func closeFrames() throws {
        let close = WebSocketFrame.close(.policyViolation, reason: "unpaired")
        #expect(close.opcode == .close)
        #expect(close.closeCode == 1008)
        #expect(close.payload.count == 2 + 8)

        let trimmed = WebSocketFrame.close(
            .tryAgainLater, reason: String(repeating: "x", count: 500)
        )
        #expect(trimmed.payload.count == 125)
        #expect(trimmed.closeCode == 1013)
    }

    @Test("a non-close frame has no close code")
    func noCloseCode() {
        #expect(WebSocketFrame.text("hi").closeCode == nil)
        #expect(WebSocketFrame(opcode: .close, payload: Data([0x03])).closeCode == nil)
    }

    // MARK: - Fragmentation

    @Test("fragments assemble into one message")
    func fragmentAssembly() throws {
        var assembler = WebSocketMessageAssembler()
        #expect(
            try assembler.accept(
                WebSocketFrame(isFinal: false, opcode: .text, payload: Data("Hel".utf8))
            ) == nil
        )
        #expect(
            try assembler.accept(
                WebSocketFrame(isFinal: false, opcode: .continuation, payload: Data("l".utf8))
            ) == nil
        )
        let message = try #require(
            try assembler.accept(
                WebSocketFrame(isFinal: true, opcode: .continuation, payload: Data("o".utf8))
            )
        )
        #expect(message.opcode == .text)
        #expect(message.text == "Hello")
    }

    @Test("a ping between two fragments passes through without disturbing the message")
    func interleavedControlFrame() throws {
        var assembler = WebSocketMessageAssembler()
        _ = try assembler.accept(
            WebSocketFrame(isFinal: false, opcode: .text, payload: Data("Hel".utf8))
        )
        let ping = try #require(try assembler.accept(.ping(Data("p".utf8))))
        #expect(ping.opcode == .ping)
        let message = try #require(
            try assembler.accept(
                WebSocketFrame(isFinal: true, opcode: .continuation, payload: Data("lo".utf8))
            )
        )
        #expect(message.text == "Hello")
    }

    @Test("a continuation with nothing open, and a data frame interleaved, are refused")
    func fragmentationErrors() throws {
        var orphan = WebSocketMessageAssembler()
        #expect(throws: WebSocketMessageAssembler.Failure.unexpectedContinuation) {
            try orphan.accept(WebSocketFrame(opcode: .continuation, payload: Data()))
        }

        var interleaved = WebSocketMessageAssembler()
        _ = try interleaved.accept(WebSocketFrame(isFinal: false, opcode: .text, payload: Data()))
        #expect(throws: WebSocketMessageAssembler.Failure.interleavedDataFrame) {
            try interleaved.accept(WebSocketFrame(opcode: .text, payload: Data()))
        }
    }

    @Test("the cap applies to the assembled total, not to each fragment")
    func fragmentedOversize() throws {
        var assembler = WebSocketMessageAssembler()
        let chunk = Data(repeating: 0x61, count: BridgeLimits.frame / 2)
        _ = try assembler.accept(WebSocketFrame(isFinal: false, opcode: .binary, payload: chunk))
        _ = try assembler.accept(
            WebSocketFrame(isFinal: false, opcode: .continuation, payload: chunk)
        )
        #expect(throws: WebSocketMessageAssembler.Failure.messageTooLarge) {
            try assembler.accept(
                WebSocketFrame(isFinal: true, opcode: .continuation, payload: Data("one too many".utf8))
            )
        }
        #expect(WebSocketMessageAssembler.Failure.messageTooLarge.closeCode == .messageTooBig)
    }
}
