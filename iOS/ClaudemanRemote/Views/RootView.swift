import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: MacStore
    @State private var selection: PairedMac.ID?
    @State private var isAdding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.macs) { mac in
                    NavigationLink(value: mac.id) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(mac.name)
                                Text(mac.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "laptopcomputer")
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.macs[$0] }.forEach(store.remove)
                }
            }
            .navigationTitle("Macs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Label("Add Mac", systemImage: "plus") }
                }
            }
            .overlay {
                if store.macs.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs Paired", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("On your Mac, open Claudeman › Settings › Remote and turn on remote control. Then pair this device.")
                    } actions: {
                        Button("Pair a Mac") { isAdding = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        } detail: {
            if let mac = store.macs.first(where: { $0.id == selection }) {
                DashboardView(mac: mac)
                    .id(mac.id)
            } else {
                ContentUnavailableView("Select a Mac", systemImage: "laptopcomputer")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddMacView { mac in selection = mac.id }
        }
        .onAppear {
            if selection == nil, store.macs.count == 1 { selection = store.macs.first?.id }
        }
        .onChange(of: store.macs) { _, macs in
            if let selection, !macs.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }
}
