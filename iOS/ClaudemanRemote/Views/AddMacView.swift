import ClaudemanKit
import SwiftUI

struct AddMacView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = Discovery()
    var onPaired: (PairedMac) -> Void

    @State private var host = ""
    @State private var port = String(RemoteAPI.defaultPort)
    @State private var resolving: String?
    @State private var target: PairTarget?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
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
                        target = PairTarget(name: nil, host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? RemoteAPI.defaultPort)
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
        .onAppear { discovery.start() }
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
        target = PairTarget(name: mac.name, host: resolved.host, port: resolved.port)
    }
}

struct PairTarget: Hashable {
    var name: String?
    var host: String
    var port: UInt16
}

struct PairView: View {
    @EnvironmentObject private var store: MacStore
    let target: PairTarget
    var onPaired: (PairedMac) -> Void

    @State private var info: ServerInfo?
    @State private var infoError: String?
    @State private var code = ""
    @State private var isPairing = false
    @State private var pairError: String?
    @FocusState private var codeFocused: Bool

    private var mac: PairedMac {
        PairedMac(name: info?.name ?? target.name ?? target.host, host: target.host, port: target.port)
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
                LabeledContent("Address", value: mac.address)
            } footer: {
                if let infoError { Text(infoError) }
            }

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

            if let pairError {
                Section { Text(pairError).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await pair() }
                } label: {
                    HStack {
                        Text("Pair")
                        if isPairing { Spacer(); ProgressView() }
                    }
                }
                .disabled(code.count != 6 || isPairing || info == nil)
            }
        }
        .navigationTitle("Pair")
        .task { await loadInfo() }
        .onAppear { codeFocused = true }
    }

    private func loadInfo() async {
        guard let url = mac.baseURL else { infoError = RemoteError.badAddress.localizedDescription; return }
        do {
            let info = try await RemoteClient(baseURL: url, token: nil).info()
            guard info.apiVersion == RemoteAPI.version else {
                infoError = "This Mac runs a different version of Claudeman. Update both apps."
                return
            }
            self.info = info
        } catch {
            infoError = "Couldn't connect: \(error.localizedDescription) Check that remote control is on and the address is right."
        }
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
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
