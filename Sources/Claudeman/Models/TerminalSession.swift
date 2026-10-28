import AppKit
import SwiftTerm

/// One running (or finished) `claude` process attached to a terminal view.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let projectID: UUID
    let name: String
    let mode: LaunchMode
    let startedAt = Date()
    /// Name shown in the Claude app when Remote Control is on; nil when it's off.
    let remoteControlName: String?
    let terminalView: LocalProcessTerminalView

    @Published private(set) var title = ""
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?

    /// Called whenever `isRunning` changes so the app model can refresh badges.
    var onStateChange: (() -> Void)?

    init(project: Project, name: String, mode: LaunchMode, preferences: TerminalPreferences) {
        self.projectID = project.id
        self.name = name
        self.mode = mode
        remoteControlName = UserDefaults.standard.remoteControlEnabled ? "\(project.name) · \(name)" : nil

        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.processDelegate = self
        apply(preferences)

        start(in: project.path, command: UserDefaults.standard.claudeCommand)
    }

    private func start(in directory: String, command: String) {
        // Run through a login shell so the user's PATH (and therefore `claude`) is found
        // even when the app is launched from Finder. "$@" forwards the mode's flags safely.
        terminalView.startProcess(
            executable: Shell.loginShell,
            args: Shell.arguments(script: "exec \(command) \"$@\"", arguments),
            environment: Shell.environment().map { "\($0.key)=\($0.value)" },
            currentDirectory: directory
        )
        isRunning = true
    }

    private var arguments: [String] {
        var arguments = mode.arguments
        // Lets the session be continued from the Claude mobile app or claude.ai/code,
        // with full chat, image attachments and permission prompts.
        if let remoteControlName { arguments += ["--remote-control", remoteControlName] }
        return arguments
    }

    /// Applies colours, font and input options. Safe to call on a running session.
    func apply(_ preferences: TerminalPreferences) {
        if terminalView.font != preferences.font {
            terminalView.font = preferences.font
        }
        preferences.theme.apply(to: terminalView)
        terminalView.setCursorStyle(preferences.cursorStyle)
        terminalView.optionAsMetaKey = preferences.optionAsMeta
        terminalView.needsDisplay = true
    }

    func terminate() {
        guard isRunning else { return }
        terminalView.terminate()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    private func markEnded(exitCode: Int32?) {
        self.exitCode = exitCode
        isRunning = false
        onStateChange?()
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        markEnded(exitCode: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        markEnded(exitCode: nil)
    }
}
