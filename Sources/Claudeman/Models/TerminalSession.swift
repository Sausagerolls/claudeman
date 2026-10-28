import AppKit
import ClaudemanKit
import SwiftTerm

/// One running (or finished) `claude` process attached to a terminal view.
///
/// The process is driven directly through `LocalProcess` rather than `LocalProcessTerminalView`
/// so its output can go to two places: the visible terminal view on the Mac, and a hidden
/// mirror `Terminal` whose screen the remote API can read for the iPhone/iPad app.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let projectID: UUID
    let projectPath: String
    let name: String
    let mode: LaunchMode
    let startedAt = Date()
    let terminalView: TerminalView

    /// Claude Code's own session id, which names its transcript file. Known up front for new
    /// sessions (we pass `--session-id`); discovered from the transcript folder otherwise.
    var claudeSessionID: String?

    @Published private(set) var title = ""
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?

    /// Called whenever `isRunning` changes so the app model can refresh badges.
    var onStateChange: (() -> Void)?

    private var process: LocalProcess!
    private let mirror: Terminal
    private let mirrorDelegate = MirrorDelegate()
    private var cols = 80
    private var rows = 24

    init(project: Project, name: String, mode: LaunchMode, preferences: TerminalPreferences) {
        self.projectID = project.id
        self.projectPath = project.path
        self.name = name
        self.mode = mode
        if mode == .new { claudeSessionID = UUID().uuidString.lowercased() }

        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        mirror = Terminal(delegate: mirrorDelegate)
        terminalView.terminalDelegate = self
        apply(preferences)
        estimateSize(of: terminalView.frame.size)

        process = LocalProcess(delegate: self, dispatchQueue: .main)
        start(in: project.path, command: UserDefaults.standard.claudeCommand)
    }

    private func start(in directory: String, command: String) {
        var arguments = mode.arguments
        if mode == .new, let claudeSessionID { arguments += ["--session-id", claudeSessionID] }

        // Run through a login shell so the user's PATH (and therefore `claude`) is found
        // even when the app is launched from Finder. "$@" forwards the flags safely.
        process.startProcess(
            executable: Shell.loginShell,
            args: Shell.arguments(script: "exec \(command) \"$@\"", arguments),
            environment: Shell.environment().map { "\($0.key)=\($0.value)" },
            currentDirectory: directory
        )
        isRunning = true
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
        process.terminate()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: Remote access

    /// The visible screen as plain text, one string per row.
    func screen() -> ScreenSnapshot {
        let lines = (0..<mirror.rows).map { row in
            // Cells skipped with cursor movement hold NUL; a terminal draws them as spaces.
            (mirror.getLine(row: row)?.translateToString(trimRight: true) ?? "")
                .replacingOccurrences(of: "\u{0}", with: " ")
        }
        return ScreenSnapshot(lines: lines, cols: mirror.cols, rows: mirror.rows)
    }

    /// Types a message into the session, optionally followed by Enter.
    ///
    /// Each image path is pasted on its own, as a drag-and-drop would, so Claude Code turns it
    /// into an image attachment; the text is pasted separately so its newlines don't submit early.
    func send(text: String, imagePaths: [String], submit: Bool) async {
        guard isRunning else { return }
        for path in imagePaths {
            sendPaste(path)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if !text.isEmpty {
            if !imagePaths.isEmpty { sendPaste(" ") }
            sendPaste(text)
        }
        if submit {
            if !text.isEmpty || !imagePaths.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            press(.enter)
        }
    }

    private func sendPaste(_ text: String) {
        var bytes = [UInt8]()
        if mirror.bracketedPasteMode { bytes += Array("\u{1B}[200~".utf8) }
        bytes += Array(text.utf8)
        if mirror.bracketedPasteMode { bytes += Array("\u{1B}[201~".utf8) }
        process.send(data: bytes[...])
    }

    func press(_ key: TerminalKey) {
        guard isRunning else { return }
        process.send(data: key.bytes[...])
    }

    // MARK: Private

    /// Initial guess at the grid size, used until the view reports its real size.
    private func estimateSize(of size: CGSize) {
        let font = terminalView.font
        let cellWidth = max(1, ("W" as NSString).size(withAttributes: [.font: font]).width)
        let cellHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        resize(cols: Int(size.width / cellWidth), rows: Int(size.height / cellHeight))
    }

    private func resize(cols: Int, rows: Int) {
        let cols = max(cols, 20), rows = max(rows, 5)
        guard cols != self.cols || rows != self.rows || mirror.cols != cols || mirror.rows != rows else { return }
        self.cols = cols
        self.rows = rows
        mirror.resize(cols: cols, rows: rows)
        if process?.running == true {
            var size = windowSize
            _ = process.updateWindowSize(&size)
        }
    }

    private var windowSize: winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    private func markEnded(exitCode: Int32?) {
        self.exitCode = exitCode
        isRunning = false
        onStateChange?()
    }
}

// MARK: - Process output

extension TerminalSession: LocalProcessDelegate {
    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            terminalView.feed(byteArray: slice)
            mirror.feed(buffer: slice)
        }
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { markEnded(exitCode: exitCode) }
    }

    nonisolated func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated {
            terminalView.feed(text: "\r\nCouldn't start Claude Code: \(error)\r\n")
            markEnded(exitCode: nil)
        }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { windowSize }
    }
}

// MARK: - Terminal view events

extension TerminalSession: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Keystrokes (and terminal replies) from the Mac view go to the process.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The mirror only keeps screen state; its replies to terminal queries are dropped because
/// the visible view already answers them.
private final class MirrorDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
