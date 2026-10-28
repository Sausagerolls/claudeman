import AppKit
import SwiftUI

@main
struct ClaudemanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Claudeman", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.editorRequest = .create(folder: nil) }
                    .keyboardShortcut("n")
                Button("Clone from GitHub…") { model.isClonePresented = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                ForEach(LaunchMode.allCases) { mode in
                    Button(mode.title) {
                        if let project = model.selectedProject { model.openSession(for: project, mode: mode) }
                    }
                    .keyboardShortcut(mode.shortcut)
                    .disabled(model.selectedProject == nil)
                }
                Divider()
                Button("Close Session") {
                    if let id = model.selectedProjectID, let session = model.selectedSession(for: id) {
                        model.close(session)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.selectedProjectID.flatMap(model.selectedSession(for:)) == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

private extension LaunchMode {
    var shortcut: KeyboardShortcut {
        switch self {
        case .new: KeyboardShortcut("t")
        case .continueLast: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .resume: KeyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare SwiftPM executable rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            AppModel.shared.applyPreferences()
            RemoteAccess.shared.applySettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = AppModel.shared.runningSessionCount
        guard running > 0, UserDefaults.standard.confirmQuit else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Claudeman?"
        alert.informativeText = running == 1
            ? "1 Claude Code session is still running and will be ended."
            : "\(running) Claude Code sessions are still running and will be ended."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
