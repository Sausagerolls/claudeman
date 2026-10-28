import SwiftUI

@main
struct ClaudemanRemoteApp: App {
    @StateObject private var store = MacStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Color("AccentColor"))
        }
    }
}
