import ClaudemanKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(SettingsKey.textSize) private var textSize = TextSize.system
    @AppStorage(SettingsKey.showToolSteps) private var showToolSteps = true
    @AppStorage(SettingsKey.refreshSpeed) private var refreshSpeed = RefreshSpeed.normal
    @AppStorage(SettingsKey.photoSize) private var photoSize = PhotoSize.standard
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.confirmStop) private var confirmStop = true
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = false
    @AppStorage(SettingsKey.defaultLaunchMode) private var defaultLaunchMode = RemoteLaunchMode.new

    @State private var macToForget: PairedMac?

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Text Size", selection: $textSize) {
                        ForEach(TextSize.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    Toggle("Show Tool Steps", isOn: $showToolSteps)
                    Toggle("Keep Screen On in Chats", isOn: $keepAwake)
                    Picker("Refresh Speed", selection: $refreshSpeed) {
                        ForEach(RefreshSpeed.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Tool steps are the “Read”, “Edit” and “Bash” rows between messages. Battery Saver checks the Mac less often; Fast feels more live but uses more battery.")
                }

                Section {
                    Picker("Upload Size", selection: $photoSize) {
                        ForEach(PhotoSize.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Photos are resized before sending. Smaller uploads faster; Large keeps more detail for screenshots and documents.")
                }

                Section {
                    Picker("Tapping + Starts", selection: $defaultLaunchMode) {
                        ForEach(RemoteLaunchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Ask Before Stopping a Session", isOn: $confirmStop)
                    Toggle("Haptics", isOn: $haptics)
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Tap + on a project to start this kind of session. Touch and hold + for the other option.")
                }

                Section("Paired Macs") {
                    if store.macs.isEmpty {
                        Text("No Macs paired.").foregroundStyle(.secondary)
                    }
                    ForEach(store.macs) { mac in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(mac.name)
                                    Text(mac.address).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "laptopcomputer")
                            }
                            Spacer()
                            Button("Forget", role: .destructive) { macToForget = mac }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/Sausagerolls/claudeman")!) {
                        Label("Claudeman on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Forget \(macToForget?.name ?? "Mac")?",
                isPresented: Binding(get: { macToForget != nil }, set: { if !$0 { macToForget = nil } }),
                titleVisibility: .visible,
                presenting: macToForget
            ) { mac in
                Button("Forget", role: .destructive) { store.remove(mac) }
            } message: { _ in
                Text("You'll need to pair again to control this Mac.")
            }
        }
    }
}
