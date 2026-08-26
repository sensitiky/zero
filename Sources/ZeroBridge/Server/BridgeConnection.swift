import Foundation

/// One accepted connection, from the first byte to the last.
///
/// A connection starts in HTTP mode. A request carrying `Upgrade: websocket` and an accepted
/// subscription moves it to frame mode for the rest of its life; anything else is served and, unless
/// keep-alive, closed (FR-1).
///
/// An actor because it owns a parser, a decoder and an assembler, all of which are mutable state fed
/// by exactly one task — and because none of it may touch the main actor (FR-6).
actor BridgeConnection {

    private let socket: Socket
    private let handler: any BridgeRequestHandling
    private let hub: EventHub
    private let pingInterval: Duration

    /// Set while this connection is in frame mode, so `shutdown` can close the client cleanly
    /// instead of pulling the socket out from under a close frame that has not been written yet.
    private var channel: ClientChannel?
    private var writer: Task<Void, Never>?

    init(
        socket: Socket,
        handler: any BridgeRequestHandling,
        hub: EventHub,
        pingInterval: Duration = BridgeLimits.pingInterval
    ) {
        self.socket = socket
        self.handler = handler
        self.hub = hub
        self.pingInterval = pingInterval
    }

    func run() async {
        do {
            try await socket.start()
            try await serveHTTP()
        } catch {
            // Nothing is logged here on purpose: the only things this error could describe are a
            // peer that went away and a request we already refused, and the bodies involved are
            // transcript content and a pairing code.
        }
        socket.close()
    }

    /// Stop this connection on purpose — the bridge was switched off (FR-2).
    ///
    /// A WebSocket client is told *why* before the socket goes: the close frame is queued, the
    /// writer is allowed to drain it, and only then is the connection cancelled. Cancelling first
    /// gives the phone a `1006` "connection lost", which is indistinguishable from a bad Wi-Fi.
    func shutdown() async {
        if let channel {
            channel.close(.goingAway, reason: "bridge stopped")
            await writer?.value
        }
        socket.close()
    }

    // MARK: - HTTP mode

    private func serveHTTP() async throws {
        var parser = HTTPRequestParser()
        while !Task.isCancelled {
            guard let chunk = try await socket.receive() else { return }
            parser.append(chunk)

            while !Task.isCancelled {
                let request: HTTPRequest?
                do {
                    request = try parser.nextRequest()
                } catch let failure as HTTPRequestParser.Failure {
                    // Over the cap or malformed: answer in the contract's shape, then close. A
                    // connection we could not understand is not one to keep reading from.
                    try? await write(HTTPResponse.error(failure.bridgeError))
                    return
                }
                guard let request else { break }

                if WebSocketHandshake.isUpgrade(request) {
                    try await upgrade(request, remainder: parser.takeRemainder())
                    return
                }

                let response = await handler.respond(to: request)
                try await write(response)
                if response.closeConnection || !request.wantsKeepAlive { return }
            }
        }
    }

    private func write(_ response: HTTPResponse) async throws {
        try await socket.send(response.serialized())
    }

    // MARK: - The upgrade

    private func upgrade(_ request: HTTPRequest, remainder: Data) async throws {
        let decision = await handler.subscribe(to: request)

        if case .reject(let response) = decision {
            try await write(response)
            return
        }

        let handshake: HTTPResponse
        do {
            handshake = try WebSocketHandshake.response(for: request)
        } catch let failure as WebSocketHandshake.Failure {
            try await write(failure.response)
            return
        }

        // The channel joins the hub *before* the `101` goes out, with the snapshot already queued.
        // Registering after the write would drop anything published while that write was in flight,
        // and a client that lost one event has a transcript that is quietly wrong from then on —
        // the exact race FR-20's snapshot exists to close.
        var channel: ClientChannel?
        if case .accept(let topic, let initial) = decision {
            let opened = ClientChannel(topic: topic)
            hub.add(opened, initial: initial)
            channel = opened
        }

        do {
            try await socket.send(handshake.serialized())
        } catch {
            if let channel {
                hub.remove(channel.id)
                channel.close(.goingAway)
            }
            throw error
        }

        switch decision {
        case .reject:
            return
        case .closeAfterUpgrade(let code, let reason):
            try await socket.send(WebSocketFrame.close(code, reason: reason).encoded())
        case .accept:
            guard let channel else { return }
            await pump(channel: channel, remainder: remainder)
        }
    }

    // MARK: - Frame mode

    private func pump(channel: ClientChannel, remainder: Data) async {
        channel.startPinging(every: pingInterval)

        // The writer is the only thing that writes to the socket from here on, so frames cannot
        // interleave: `ClientChannel` hands them over in the order they were published.
        // Detached, so draining the queue never has to wait for this actor to be free: the read
        // loop below owns the actor for as long as it is parked on a receive.
        let writer = Task.detached { [socket] in
            for await item in channel.outbound {
                // Encoded here, on a cooperative thread, never on the main actor (FR-6).
                guard let data = item.encoded() else {
                    channel.dequeued()
                    continue
                }
                do {
                    try await socket.send(data)
                } catch {
                    break
                }
                channel.dequeued()
            }
        }
        self.channel = channel
        self.writer = writer

        var decoder = WebSocketFrameDecoder()
        var assembler = WebSocketMessageAssembler()
        decoder.append(remainder)

        var closeCode = WebSocketCloseCode.goingAway
        reading: while !Task.isCancelled {
            while !Task.isCancelled {
                let frame: WebSocketFrame?
                do {
                    frame = try decoder.nextFrame()
                } catch let failure as WebSocketFrameDecoder.Failure {
                    closeCode = failure.closeCode
                    break reading
                } catch {
                    closeCode = .protocolError
                    break reading
                }
                guard let frame else { break }

                let message: WebSocketMessageAssembler.Message?
                do {
                    message = try assembler.accept(frame)
                } catch let failure as WebSocketMessageAssembler.Failure {
                    closeCode = failure.closeCode
                    break reading
                } catch {
                    closeCode = .protocolError
                    break reading
                }
                guard let message else { continue }

                switch message.opcode {
                case .ping:
                    // FR-25: the server answers pings as well as sending them.
                    channel.sendFrame(.pong(message.payload))
                case .close:
                    closeCode = .normal
                    break reading
                case .pong, .text, .binary, .continuation:
                    // The contract has no client-to-server messages: everything a client asks for
                    // it asks over HTTP. A data frame is read, bounded, and dropped.
                    break
                }
            }

            do {
                guard let chunk = try await socket.receive() else { break }
                decoder.append(chunk)
            } catch {
                break
            }
        }

        hub.remove(channel.id)
        channel.close(closeCode)
        // Let the close frame reach the wire before the socket goes.
        await writer.value
        self.channel = nil
        self.writer = nil
    }
}
