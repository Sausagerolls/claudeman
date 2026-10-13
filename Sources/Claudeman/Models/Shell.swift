import Foundation

struct ShellResult {
    let status: Int32
    let output: String
    let error: String

    var succeeded: Bool { status == 0 }
}

/// Runs commands through the user's login shell, so tools like `claude`, `git` and `gh`
/// resolve the same way they do in Terminal even when the app is launched from Finder.
enum Shell {
    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static let inheritedClaudeSessionKeys = [
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // If Claudeman was launched from inside a Claude Code session, drop that session's
        // markers so each `claude` starts as a normal top-level session (with transcripts saved)
        // and doesn't inherit the parent's messaging socket or token.
        // User configuration such as CLAUDE_CODE_USE_BEDROCK is left alone.
        for key in inheritedClaudeSessionKeys { env.removeValue(forKey: key) }

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Claudeman"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        // Common install locations, appended in case the login shell misses them.
        let home = NSHomeDirectory()
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Login-shell arguments that run `script` with `arguments` available as "$@".
    static func arguments(script: String, _ arguments: [String]) -> [String] {
        ["-l", "-c", script, "claudeman"] + arguments
    }

    /// Runs `script` and collects its output. `onStart` receives the process so callers can cancel it.
    static func run(
        _ script: String,
        arguments: [String] = [],
        in directory: String? = nil,
        onStart: ((Process) -> Void)? = nil
    ) async -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = self.arguments(script: script, arguments)
        var env = environment()
        env["GIT_TERMINAL_PROMPT"] = "0"   // never hang waiting for a password
        env["GH_PROMPT_DISABLED"] = "1"
        process.environment = env
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outBuffer = OutputBuffer(), errBuffer = OutputBuffer()
        stdout.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                outBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    output: outBuffer.string,
                    error: errBuffer.string
                ))
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                continuation.resume(returning: ShellResult(status: -1, output: "", error: error.localizedDescription))
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
