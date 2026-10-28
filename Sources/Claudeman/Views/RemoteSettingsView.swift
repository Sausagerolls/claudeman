import ClaudemanKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject private var remote = RemoteAccess.shared
    @AppStorage(SettingsKey.remoteEnabled) private var enabled = false
    @AppStorage(SettingsKey.remotePort) private var port = Int(RemoteAPI.defaultPort)

    var body: some View {
        Form {
            Section {
                Toggle("Allow remote control from iPhone and iPad", isOn: $enabled)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(!enabled)
                LabeledContent("Status") { statusLabel }
            } footer: {
                Text("Paired devices can list projects and start, restart or stop sessions. They can't see or type into a session.")
            }

            if enabled {
                Section("Addresses") {
                    let addresses = NetworkAddresses.current()
                    ForEach(addresses, id: \.address) { entry in
                        LabeledContent(label(for: entry)) {
                            Text(verbatim: "\(entry.address):\(port)").textSelection(.enabled)
                        }
                    }
                    Text("The iOS app finds this Mac automatically on the same Wi-Fi. When you're away, connect over Tailscale using its 100.x address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Paired Devices") {
                    pairing
                    if remote.devices.isEmpty {
                        Text("No devices paired yet.").foregroundStyle(.secondary)
                    }
                    ForEach(remote.devices) { device in
                        HStack {
                            Image(systemName: "iphone")
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(lastSeen(device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { remote.revoke(device) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch remote.state {
        case .stopped:
            Text("Off").foregroundStyle(.secondary)
        case .starting:
            ProgressView().controlSize(.small)
        case .listening(let port):
            Label("Listening on port \(String(port))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Retry") { remote.retry() }
            }
        }
    }

    @ViewBuilder
    private var pairing: some View {
        if let code = remote.pairingCode, let expiry = remote.pairingExpiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiry.timeIntervalSince(context.date)))
                HStack(alignment: .center, spacing: 20) {
                    if let qr = QRCode.image(for: pairingLink(code: code).url.absoluteString) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your iPhone or iPad camera, or the Claudeman Remote app.")
                        Text("Or enter this code:").foregroundStyle(.secondary)
                        Text(code.prefix(3) + " " + code.suffix(3))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Expired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { remote.cancelPairing() }
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            Button("Pair Device…") { remote.beginPairing() }
                .disabled(!isListening)
        }
    }

    private func pairingLink(code: String) -> PairingLink {
        // Local network addresses first, then Tailscale, so the phone tries the fastest path first.
        let addresses = NetworkAddresses.current()
            .sorted { isTailscale($0.address) == isTailscale($1.address) ? $0.interface < $1.interface : !isTailscale($0.address) }
            .map(\.address)
        return PairingLink(name: remote.serviceName, hosts: addresses, port: UInt16(clamping: port), code: code)
    }

    private func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts[0] == "100", let second = Int(parts[1]) else { return false }
        return (64...127).contains(second)
    }

    private var isListening: Bool {
        if case .listening = remote.state { return true }
        return false
    }

    private func label(for entry: (interface: String, address: String)) -> String {
        if isTailscale(entry.address) { return "Tailscale" }
        return entry.interface.hasPrefix("en") ? "Local network (\(entry.interface))" : entry.interface
    }

    private func lastSeen(_ device: PairedDevice) -> String {
        guard let date = device.lastSeenAt else {
            return "Paired \(device.pairedAt.formatted(.relative(presentation: .named)))"
        }
        return "Last seen \(date.formatted(.relative(presentation: .named)))"
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
