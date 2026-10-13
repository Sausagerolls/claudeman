import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ProjectSettings()
                .tabItem { Label("Projects", systemImage: "folder") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(SettingsKey.claudeCommand) private var claudeCommand = SettingsDefault.claudeCommand
    @AppStorage(SettingsKey.confirmCloseRunning) private var confirmCloseRunning = true
    @AppStorage(SettingsKey.confirmQuit) private var confirmQuit = true
    @AppStorage(SettingsKey.showProjectPaths) private var showProjectPaths = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                TextField("Claude command", text: $claudeCommand, prompt: Text(SettingsDefault.claudeCommand))
                Text("Runs through your login shell in the project folder. Add flags if you like, e.g. `claude --model opus`. Use a full path if `claude` isn't found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask before closing a running session", isOn: $confirmCloseRunning)
                Toggle("Ask before quitting with running sessions", isOn: $confirmQuit)
                Toggle("Show folder paths in the sidebar", isOn: $showProjectPaths)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettings: View {
    @AppStorage(SettingsKey.terminalTheme) private var themeID = TerminalTheme.automaticID
    @AppStorage(SettingsKey.fontName) private var fontName = SettingsDefault.fontName
    @AppStorage(SettingsKey.fontSize) private var fontSize = SettingsDefault.fontSize
    @AppStorage(SettingsKey.cursorShape) private var cursorShape = CursorShape.block
    @AppStorage(SettingsKey.cursorBlink) private var cursorBlink = false
    @AppStorage(SettingsKey.optionAsMeta) private var optionAsMeta = false
    @Environment(\.colorScheme) private var colorScheme

    private static let monospacedFonts: [String] = {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return names.sorted()
    }()

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeID) {
                    Text("Match Appearance").tag(TerminalTheme.automaticID)
                    Divider()
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                ThemePreview(
                    theme: TerminalTheme.resolve(themeID, isDark: colorScheme == .dark),
                    font: previewFont
                )
                Text("Tip: in Claude Code, run `/config` and pick a matching light or dark theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Font", selection: $fontName) {
                    Text("System Monospaced (SF Mono)").tag(SettingsDefault.fontName)
                    Divider()
                    ForEach(Self.monospacedFonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $fontSize, in: 9...28, step: 1) {
                    LabeledContent("Size", value: "\(Int(fontSize)) pt")
                }
            }
            Section {
                Picker("Cursor", selection: $cursorShape) {
                    ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blinking cursor", isOn: $cursorBlink)
                Toggle("Use Option as Meta key", isOn: $optionAsMeta)
                Text("When off, Option types special characters as in Terminal.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewFont: Font {
        fontName.isEmpty
            ? .system(size: fontSize, design: .monospaced)
            : .custom(fontName, size: fontSize)
    }
}

private struct ThemePreview: View {
    let theme: TerminalTheme
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (color(theme.ansi[2], "✻ ") + color(theme.foreground, "Welcome to Claude Code"))
            (color(theme.ansi[8], "> ") + color(theme.foreground, "fix the failing test"))
            (color(theme.ansi[4], "● ") + color(theme.ansi[3], "Update") + color(theme.foreground, "(src/app.swift)"))
            (color(theme.ansi[2], "+ added line  ") + color(theme.ansi[1], "- removed line"))
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: NSColor(hex: theme.ansi[index])))
                        .frame(width: 14, height: 10)
                }
            }
            .padding(.top, 4)
        }
        .font(font)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor(hex: theme.background)), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ hex: String, _ text: String) -> Text {
        Text(text).foregroundColor(Color(nsColor: NSColor(hex: hex)))
    }
}

private struct ProjectSettings: View {
    @AppStorage(SettingsKey.defaultLaunchMode) private var defaultLaunchMode = LaunchMode.new
    @AppStorage(SettingsKey.cloneDirectory) private var cloneDirectory = SettingsDefault.cloneDirectory
    @State private var cliReady: Bool?

    var body: some View {
        Form {
            Section {
                Picker("New project starts with", selection: $defaultLaunchMode) {
                    ForEach(LaunchMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("GitHub") {
                LabeledContent("Clone into") {
                    HStack {
                        Text((cloneDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseCloneDirectory)
                    }
                }
                LabeledContent("GitHub CLI") {
                    switch cliReady {
                    case nil: ProgressView().controlSize(.small)
                    case true: Label("Logged in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case false: Label("Not set up (`gh auth login`)", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { cliReady = await GitHub.isCLIReady() }
    }

    private func chooseCloneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: cloneDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            cloneDirectory = url.path
        }
    }
}
