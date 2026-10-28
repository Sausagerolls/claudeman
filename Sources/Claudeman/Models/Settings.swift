import AppKit
import ClaudemanKit
import SwiftTerm

enum SettingsKey {
    static let claudeCommand = "claudeCommand"
    static let appearance = "appearance"
    static let terminalTheme = "terminalTheme"
    static let fontName = "terminalFontName"
    static let fontSize = "terminalFontSize"
    static let cursorShape = "cursorShape"
    static let cursorBlink = "cursorBlink"
    static let optionAsMeta = "optionAsMeta"
    static let defaultLaunchMode = "defaultLaunchMode"
    static let confirmCloseRunning = "confirmCloseRunning"
    static let confirmQuit = "confirmQuit"
    static let showProjectPaths = "showProjectPaths"
    static let cloneDirectory = "cloneDirectory"
    static let remoteEnabled = "remoteEnabled"
    static let remotePort = "remotePort"
}

enum SettingsDefault {
    static let claudeCommand = "claude"
    static let fontName = ""   // empty means the system monospaced font (SF Mono)
    static let fontSize = 13.0
    static let cloneDirectory = (NSHomeDirectory() as NSString).appendingPathComponent("Developer")
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum CursorShape: String, CaseIterable, Identifiable {
    case block, bar, underline

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func style(blinking: Bool) -> CursorStyle {
        switch (self, blinking) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }
}

/// Snapshot of everything that affects how a terminal looks and behaves.
struct TerminalPreferences {
    var theme: TerminalTheme
    var font: NSFont
    var cursorStyle: CursorStyle
    var optionAsMeta: Bool

    /// Resolves preferences for a given effective dark/light state (used by "Match Appearance").
    static func current(isDark: Bool) -> TerminalPreferences {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.terminalFontSize)
        let font = NSFont(name: defaults.terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return TerminalPreferences(
            theme: TerminalTheme.resolve(defaults.terminalThemeID, isDark: isDark),
            font: font,
            cursorStyle: defaults.cursorShape.style(blinking: defaults.cursorBlink),
            optionAsMeta: defaults.optionAsMeta
        )
    }
}

extension UserDefaults {
    var claudeCommand: String {
        let value = string(forKey: SettingsKey.claudeCommand)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? SettingsDefault.claudeCommand : value
    }

    var appearance: AppAppearance {
        string(forKey: SettingsKey.appearance).flatMap(AppAppearance.init) ?? .system
    }

    var terminalThemeID: String {
        string(forKey: SettingsKey.terminalTheme) ?? TerminalTheme.automaticID
    }

    var terminalFontName: String {
        string(forKey: SettingsKey.fontName) ?? SettingsDefault.fontName
    }

    var terminalFontSize: Double {
        let value = double(forKey: SettingsKey.fontSize)
        return value > 0 ? value : SettingsDefault.fontSize
    }

    var cursorShape: CursorShape {
        string(forKey: SettingsKey.cursorShape).flatMap(CursorShape.init) ?? .block
    }

    var cursorBlink: Bool { bool(forKey: SettingsKey.cursorBlink) }
    var optionAsMeta: Bool { bool(forKey: SettingsKey.optionAsMeta) }

    var defaultLaunchMode: LaunchMode {
        string(forKey: SettingsKey.defaultLaunchMode).flatMap(LaunchMode.init) ?? .new
    }

    var confirmCloseRunning: Bool { object(forKey: SettingsKey.confirmCloseRunning) as? Bool ?? true }
    var confirmQuit: Bool { object(forKey: SettingsKey.confirmQuit) as? Bool ?? true }

    var remoteEnabled: Bool { bool(forKey: SettingsKey.remoteEnabled) }

    var remotePort: UInt16 {
        let value = integer(forKey: SettingsKey.remotePort)
        return (1024...65535).contains(value) ? UInt16(value) : RemoteAPI.defaultPort
    }

    var cloneDirectory: String {
        let value = string(forKey: SettingsKey.cloneDirectory) ?? ""
        return value.isEmpty ? SettingsDefault.cloneDirectory : value
    }
}
