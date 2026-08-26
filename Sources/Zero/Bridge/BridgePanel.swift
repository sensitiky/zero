import SwiftUI
import ZeroBridge

/// The bridge's one surface (FR-27): its state, where it is reachable, the pairing code, and how
/// many clients are connected.
///
/// A switch and a code, not a settings pane. The code is the only thing here with any visual
/// weight, because it is the only thing that gets read out loud.
struct BridgePanel: View {

    @Bindable var bridge: BridgeController
    @Environment(\.colorScheme) private var scheme
    /// The panel is a column of label/value rows, so it has to widen with the text in it or the
    /// address wraps onto its own line.
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            state
            if bridge.isListening {
                listening
            } else {
                stopped
            }
            footer
        }
        .padding(16)
        .frame(width: width)
    }

    // MARK: - Sections

    private var state: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("BRIDGE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text(bridge.isListening ? "Listening" : "Off")
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bridge.isListening ? "Bridge listening" : "Bridge off")
    }

    @ViewBuilder
    private var listening: some View {
        if let address = bridge.primaryAddress {
            row("Address", address)
        } else {
            // Listening on a port nobody can reach. Saying so beats showing a URL that fails.
            row("Address", "no network")
        }

        if let code = bridge.pairingCode {
            VStack(alignment: .leading, spacing: 5) {
                Text("PAIR")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                Text(code.displayGrouped)
                    .font(Theme.code(.title2, weight: .medium))
                    .textSelection(.enabled)
                    .accessibilityLabel(Self.spelled(code.displayDigits))
            }
        }

        // Every other address, for a Mac on more than one network — Wi-Fi and Ethernet at a desk is
        // the ordinary case, and the one it answers on is not always the first.
        if bridge.addresses.count > 1 {
            Text(bridge.addresses.dropFirst().map { "\($0):\(bridge.port)" }.joined(separator: "  "))
                .font(.caption)
                .foregroundStyle(Theme.secondary(scheme))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var stopped: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Port")
                .foregroundStyle(Theme.secondary(scheme))
            Spacer(minLength: 12)
            // Editable only while stopped: changing the port of a running listener is a restart
            // wearing a text field.
            TextField("Port", value: $bridge.port, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityLabel("Bridge port")
        }
        .font(.callout)

        Text("Off until you turn it on. Nothing is reachable while it is off.")
            .font(.caption)
            .foregroundStyle(Theme.secondary(scheme))

        if let error = bridge.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.secondary(scheme))
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(clients)
                .font(.caption)
                .foregroundStyle(Theme.secondary(scheme))
            Spacer(minLength: 12)
            Button(bridge.isListening ? "Stop" : "Start") {
                Task { await bridge.toggle() }
            }
            .accessibilityLabel(bridge.isListening ? "Stop the bridge" : "Start the bridge")
        }
    }

    // MARK: - Pieces

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Theme.secondary(scheme))
            Spacer(minLength: 12)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var clients: String {
        guard bridge.isListening else { return "No devices can connect" }
        switch bridge.clientCount {
        case 0: return "No devices connected"
        case 1: return "1 device connected"
        default: return "\(bridge.clientCount) devices connected"
        }
    }

    /// "418205" as "4 1 8 2 0 5", so VoiceOver reads six digits instead of "four hundred eighteen
    /// thousand two hundred five" — which is a number nobody can type into a phone.
    private static func spelled(_ digits: String) -> String {
        "Pairing code: " + digits.map(String.init).joined(separator: " ")
    }
}
