import Darwin
import Foundation
import Observation
import SwiftUI
import ZeroBridge

/// The switch, and everything that has to be true while it is on (FR-2, FR-3, FR-4, FR-27).
///
/// Off at launch, always. Nothing here restores a previous state, and that is deliberate: a listener
/// that comes back on its own is a listener you forgot about (PRD Open question 3).
@MainActor
@Observable
final class BridgeController {

    /// Configurable, `4000` by default (FR-3). Editable only while stopped — changing the port of a
    /// running listener is a restart wearing a text field.
    var port: UInt16 = BridgeLimits.defaultPort

    private(set) var isListening = false
    /// Regenerated on every start (FR-4). Shown in the window and nowhere else.
    private(set) var pairingCode: PairingCode?
    private(set) var clientCount = 0
    /// The LAN addresses this is reachable at, so the user does not have to look up their own IP.
    private(set) var addresses: [String] = []
    /// Why the last start failed, in safe text. Never the code, never a request.
    private(set) var lastError: String?

    private let model: AppModel
    private let coordinator: SessionCoordinator

    private var server: BridgeServer?
    private var hub: EventHub?
    private var adapter: BridgeHostAdapter?
    private var clientCountPoll: Task<Void, Never>?

    init(model: AppModel, coordinator: SessionCoordinator) {
        self.model = model
        self.coordinator = coordinator
    }

    /// The address a phone types, or nil when nothing is reachable — a Mac with no network is
    /// listening on a port nobody can reach, and saying so is better than showing a URL that fails.
    var primaryAddress: String? {
        guard isListening, let host = addresses.first else { return nil }
        return "http://\(host):\(port)"
    }

    // MARK: - Start and stop

    func start() async {
        guard !isListening else { return }
        lastError = nil

        let hub = EventHub()
        let adapter = BridgeHostAdapter(model: model, coordinator: coordinator, hub: hub)
        let code = PairingCode()
        let server = BridgeServer(
            handler: BridgeRouter(host: adapter, pairingCode: code),
            hub: hub
        )

        do {
            let bound = try await server.start(port: port)
            self.server = server
            self.hub = hub
            self.adapter = adapter
            port = bound
            pairingCode = code
            addresses = Self.localAddresses()
            isListening = true
            adapter.resetPublishedState()
            // FR-24: the one hook, installed only while the bridge is on. With it nil — which is
            // every other moment in this app's life — each publish point is a no-op.
            coordinator.eventSink = { [weak adapter] sessionID, publication in
                adapter?.publish(sessionID, publication)
            }
            startCountingClients(hub)
        } catch {
            await server.stop()
            lastError = Self.message(for: error, port: port)
        }
    }

    func stop() async {
        coordinator.eventSink = nil
        clientCountPoll?.cancel()
        clientCountPoll = nil
        await server?.stop()
        server = nil
        hub = nil
        adapter = nil
        isListening = false
        pairingCode = nil
        clientCount = 0
        addresses = []
    }

    func toggle() async {
        if isListening {
            await stop()
        } else {
            await start()
        }
    }

    /// Polled rather than pushed: the count is a number on a panel that nobody is watching by the
    /// second, and pushing it would mean the transport calling into the main actor on every connect
    /// and disconnect for a label.
    private func startCountingClients(_ hub: EventHub) {
        clientCountPoll?.cancel()
        clientCountPoll = Task { [weak self] in
            while !Task.isCancelled {
                self?.clientCount = hub.clientCount
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// Safe text only. `error` here can hold a `POSIXError`, and the one that matters is worth
    /// naming: a port already in use is the ordinary failure and the one with an obvious fix.
    private static func message(for error: any Error, port: UInt16) -> String {
        if case BridgeServer.Failure.listenerFailed(let detail) = error,
           detail.contains("Address already in use") || detail.contains("addrInUse") {
            return "Port \(port) is already in use. Try another port."
        }
        if case BridgeServer.Failure.invalidPort(let value) = error {
            return "\(value) is not a port this can listen on."
        }
        return "The bridge could not start on port \(port)."
    }

    // MARK: - Addresses

    /// Every IPv4 address on an interface that is up and not loopback.
    ///
    /// IPv4 only, and not because IPv6 does not work: the address a person reads off a screen and
    /// types into a phone is `192.168.1.10`, and showing an `fe80::` link-local next to it is noise
    /// on a panel whose whole job is to be read at a glance.
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [UInt8](repeating: 0, count: Int(NI_MAXHOST))
            let status = host.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress.map {
                    $0.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                        getnameinfo(
                            address,
                            socklen_t(address.pointee.sa_len),
                            chars,
                            socklen_t(buffer.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                    }
                } ?? EAI_FAIL
            }
            guard status == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }, as: UTF8.self)
            guard !text.isEmpty, !found.contains(text) else { continue }
            found.append(text)
        }
        return found
    }

    // MARK: - Previews

    /// Makes this controller *look* listening without binding anything, so `ZeroPreview.app` shows
    /// the panel with an address, a code and a client count without a phone on the network (FR-28).
    ///
    /// Reached only from `PreviewData`, which runs only under `ZERO_PREVIEW=1`. Stopping in the
    /// preview leaves the controller genuinely stopped, which is how both states are covered by one
    /// build: the panel starts listening and the Stop button shows the other half.
    func seedPreviewState(
        code: String = "418205",
        clients: Int = 1,
        address: String = "192.168.1.10"
    ) {
        isListening = true
        pairingCode = PairingCode(code)
        clientCount = clients
        addresses = [address]
    }
}
