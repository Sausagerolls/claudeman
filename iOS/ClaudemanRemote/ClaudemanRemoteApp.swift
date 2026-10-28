import SwiftUI

@main
struct ClaudemanRemoteApp: App {
    @StateObject private var store = MacStore()
    @AppStorage(SettingsKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(SettingsKey.textSize) private var textSize = TextSize.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Color("AccentColor"))
                .preferredColorScheme(appearance.colorScheme)
                .modifier(TextSizeModifier(size: textSize.dynamicTypeSize))
        }
    }
}

/// Applies the Text Size setting, or leaves the system size alone.
private struct TextSizeModifier: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size { content.dynamicTypeSize(size) } else { content }
    }
}
