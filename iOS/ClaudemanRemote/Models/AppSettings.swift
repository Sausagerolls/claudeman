import ClaudemanKit
import SwiftUI
import UIKit

enum SettingsKey {
    static let appearance = "appearance"
    static let textSize = "textSize"
    static let showToolSteps = "showToolSteps"
    static let refreshSpeed = "refreshSpeed"
    static let photoSize = "photoSize"
    static let haptics = "haptics"
    static let confirmStop = "confirmStop"
    static let keepAwake = "keepAwakeInChat"
    static let defaultLaunchMode = "defaultLaunchMode"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TextSize: String, CaseIterable, Identifiable {
    case system, small, large, extraLarge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .small: "Small"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .small: .small
        case .large: .xLarge
        case .extraLarge: .xxxLarge
        }
    }
}

enum RefreshSpeed: String, CaseIterable, Identifiable {
    case batterySaver, normal, fast

    var id: String { rawValue }
    var title: String {
        switch self {
        case .batterySaver: "Battery Saver"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Multiplies each screen's normal polling interval.
    var multiplier: Double {
        switch self {
        case .batterySaver: 2.5
        case .normal: 1
        case .fast: 0.6
        }
    }
}

enum PhotoSize: String, CaseIterable, Identifiable {
    case small, standard, large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Smaller (faster)"
        case .standard: "Standard"
        case .large: "Large (more detail)"
        }
    }

    var maxSide: CGFloat {
        switch self {
        case .small: 1280
        case .standard: 2048
        case .large: 3072
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .small: 0.7
        case .standard: 0.8
        case .large: 0.9
        }
    }
}

/// Reads settings outside views (helpers, models).
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var hapticsEnabled: Bool { defaults.object(forKey: SettingsKey.haptics) as? Bool ?? true }
    static var confirmStop: Bool { defaults.object(forKey: SettingsKey.confirmStop) as? Bool ?? true }
    static var refreshSpeed: RefreshSpeed {
        defaults.string(forKey: SettingsKey.refreshSpeed).flatMap(RefreshSpeed.init) ?? .normal
    }
    static var photoSize: PhotoSize {
        defaults.string(forKey: SettingsKey.photoSize).flatMap(PhotoSize.init) ?? .standard
    }
    static var defaultLaunchMode: RemoteLaunchMode {
        defaults.string(forKey: SettingsKey.defaultLaunchMode).flatMap(RemoteLaunchMode.init) ?? .new
    }

    /// A polling interval adjusted for the refresh-speed setting.
    static func interval(_ base: Duration) -> Duration {
        base * refreshSpeed.multiplier
    }
}

/// Haptic feedback that respects the Haptics setting.
enum Haptics {
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppSettings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard AppSettings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
