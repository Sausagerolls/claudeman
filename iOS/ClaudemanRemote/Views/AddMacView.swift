import ClaudemanKit
import SwiftUI

struct AddMacView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = Discovery()
    /// Set when the app was opened from a scanned pairing link.
    var initialLink: PairingLink?
    var onPaired: (PairedMac) -> Void

    @State private var host = ""
    @State private var port = String(RemoteAPI.defaultPort)
    @State private var resolving: String?
    @State private var target: PairTarget?
    @State private var message: String?
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                } footer: {
                    Text("On your Mac, open Claudeman › Settings › Remote and click “Pair Device…”. You can also scan the code with the Camera app.")
                }

                Section {
                    if discovery.macs.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for Macs…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(discovery.macs) { mac in
                        Button {
                            Task { await choose(mac) }
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "laptopcomputer")
                                Spacer()
                                if resolving == mac.id { ProgressView() }
                            }
                        }
                        .disabled(resolving != nil)
                    }
                } header: {
                    Text("On This Network")
                } footer: {
                    if let problem = discovery.problem {
                        Text(problem)
                    } else {
                        Text("Your Mac appears here when Claudeman is open and remote control is on.")
                    }
                }

                Section {
                    TextField("Host name or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Button("Continue") {
                        target = PairTarget(name: nil, hosts: [host.trimmingCharacters(in: .whitespaces)], port: UInt16(port) ?? RemoteAPI.defaultPort)
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port) == nil)
                } header: {
                    Text("Enter Address")
                } footer: {
                    Text("Away from home? Install Tailscale on both devices and use the Mac's Tailscale address (100.x.x.x) or MagicDNS name, shown in Claudeman › Settings › Remote.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $target) { target in
                PairView(target: target) { mac in
                    onPaired(mac)
                    dismiss()
                }
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            QRScannerView { value in
                if let url = URL(string: value), let link = PairingLink(url: url) {
                    target = PairTarget(link)
                } else {
                    message = "That QR code isn't a Claudeman pairing code."
                }
            }
        }
        .onAppear {
            discovery.start()
            if let initialLink, target == nil { target = PairTarget(initialLink) }
        }
        .onDisappear { discovery.stop() }
    }

    private func choose(_ mac: DiscoveredMac) async {
        message = nil
        resolving = mac.id
        defer { resolving = nil }
        guard let resolved = await Discovery.resolve(mac) else {
            message = "Couldn't reach \(mac.name). Make sure both devices are on the same network."
            return
        }
        target = PairTarget(name: mac.name, hosts: [resolved.host], port: resolved.port)
    }
}

struct PairTarget: Hashable {
    var name: String?
    /// Candidate addresses; the first that answers is used.
    var hosts: [String]
    var port: UInt16
    /// Present when pairing from a QR code, so no typing is needed.
    var code: String?

    init(name: String?, hosts: [String], port: UInt16, code: String? = nil) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.code = code
    }

    init(_ link: PairingLink) {
        self.init(name: link.name, hosts: link.hosts, port: link.port, code: link.code)
    }
}

struct PairView: View {
    @EnvironmentObject private var store: MacStore
    let target: PairTarget
    var onPaired: (PairedMac) -> Void

    @State private var host: String?
    @State private var info: ServerInfo?
    @State private var infoError: String?
    @State private var code = ""
    @State private var isPairing = false
    @State private var pairError: String?
    @FocusState private var codeFocused: Bool

    private var mac: PairedMac {
        PairedMac(name: info?.name ?? target.name ?? target.hosts.first ?? "Mac", host: host ?? target.hosts.first ?? "", port: target.port)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Mac") {
                    if let info {
                        Text(info.name)
                    } else if infoError != nil {
                        Text("Unreachable").foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
                LabeledContent("Address", value: host.map { "\($0):\(target.port)" } ?? target.hosts.map { "\($0):\(target.port)" }.joined(separator: ", "))
            } footer: {
                if let infoError { Text(infoError) }
            }

            if target.code == nil || pairError != nil {
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .focused($codeFocused)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                        }
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("On the Mac, open Claudeman › Settings › Remote and click “Pair Device…”.")
                }
            }

            if let pairError {
                Section { Text(pairError).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await pair() }
                } label: {
                    HStack {
                        Text(isPairing ? "Pairing…" : "Pair")
                        if isPairing { Spacer(); ProgressView() }
                    }
                }
                .disabled(code.count != 6 || isPairing || info == nil)
            }
        }
        .navigationTitle("Pair")
        .task {
            if let scanned = target.code { code = scanned }
            await connect()
            // A scanned QR code carries the code too, so pair straight away.
            if target.code != nil, info != nil { await pair() }
        }
        .onAppear { if target.code == nil { codeFocused = true } }
    }

    /// Tries every candidate address at once and keeps the first Mac that answers.
    private func connect() async {
        let port = target.port
        let result: (String, ServerInfo)? = await withTaskGroup(of: (String, ServerInfo)?.self) { group in
            for candidate in target.hosts {
                group.addTask {
                    let mac = PairedMac(name: "", host: candidate, port: port)
                    guard let url = mac.baseURL,
                          let info = try? await RemoteClient(baseURL: url, token: nil).info() else { return nil }
                    return (candidate, info)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let (host, info) = result else {
            infoError = "Couldn't connect. Check that remote control is on, and that this device is on the same network as the Mac (or on Tailscale)."
            return
        }
        guard info.apiVersion == RemoteAPI.version else {
            infoError = "This Mac runs a different version of Claudeman. Update both apps."
            return
        }
        self.host = host
        self.info = info
    }

    private func pair() async {
        guard let url = mac.baseURL else { return }
        isPairing = true
        pairError = nil
        defer { isPairing = false }
        do {
            let response = try await RemoteClient(baseURL: url, token: nil)
                .pair(code: code, deviceName: UIDevice.current.name)
            var paired = mac
            paired.name = response.server.name
            store.add(paired, token: response.token)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onPaired(paired)
        } catch {
            pairError = error.localizedDescription
            code = ""
            codeFocused = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
