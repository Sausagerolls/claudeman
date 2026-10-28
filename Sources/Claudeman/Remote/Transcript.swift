import ClaudemanKit
import Foundation

/// Reads a Claude Code session transcript (`~/.claude/projects/<project>/<session-id>.jsonl`)
/// incrementally and turns it into simple chat messages for the iOS app.
///
/// The transcript format is internal to Claude Code, so parsing is deliberately forgiving:
/// unknown record types and fields are skipped.
@MainActor
final class TranscriptReader {
    let url: URL
    private(set) var messages: [ChatMessage] = []
    /// Bumped whenever `messages` is rebuilt from scratch, so clients know to reset.
    private(set) var generation = 0

    private var offset: UInt64 = 0
    private var partialLine = Data()

    init(url: URL) {
        self.url = url
    }

    /// Reads anything appended since the last call.
    func refresh() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // The file was rewritten; start over.
            offset = 0
            partialLine = Data()
            messages = []
            generation += 1
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offset += UInt64(data.count)

        var buffer = partialLine + data
        if let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
            partialLine = buffer[(lastNewline + 1)...]
            buffer = buffer[..<lastNewline]
        } else {
            partialLine = buffer
            return
        }
        for line in buffer.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            messages += Self.messages(from: object)
        }
    }

    // MARK: Locating transcripts

    /// `~/.claude`, or `$CLAUDE_CONFIG_DIR` when set.
    static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Claude Code stores each project's transcripts in a folder named after its path,
    /// with every non-alphanumeric character replaced by "-".
    static func projectDirectory(for path: String) -> URL {
        let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return configDirectory.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    static func transcriptURL(projectPath: String, sessionID: String) -> URL {
        projectDirectory(for: projectPath).appendingPathComponent("\(sessionID).jsonl")
    }

    /// Transcript files in a project folder, newest first.
    static func transcripts(projectPath: String) -> [(id: String, modified: Date)] {
        let directory = projectDirectory(for: projectPath)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url.deletingPathExtension().lastPathComponent, modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    // MARK: Parsing

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func messages(from record: [String: Any]) -> [ChatMessage] {
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return [] }

        let id = record["uuid"] as? String ?? UUID().uuidString
        let timestamp = (record["timestamp"] as? String).flatMap(isoFormatter.date(from:))

        if type == "user" {
            return userMessage(id: id, content: message["content"], timestamp: timestamp).map { [$0] } ?? []
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { index, block in
            let blockID = "\(id)-\(index)"
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : ChatMessage(id: blockID, kind: .assistant, text: text, timestamp: timestamp)
            case "tool_use":
                let name = displayName(forTool: block["name"] as? String ?? "Tool")
                let summary = toolSummary(block["input"] as? [String: Any] ?? [:])
                return ChatMessage(id: blockID, kind: .tool, text: summary, toolName: name, timestamp: timestamp)
            default:
                return nil
            }
        }
    }

    private static func userMessage(id: String, content: Any?, timestamp: Date?) -> ChatMessage? {
        var texts: [String] = []
        var images = 0

        if let string = content as? String {
            texts.append(string)
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text": texts.append(block["text"] as? String ?? "")
                case "image": images += 1
                default: break   // tool results are shown through the tool call instead
                }
            }
        }

        var parts: [String] = []
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let command = slashCommand(in: text) {
                parts.append(command)
            } else if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("Caveat:") {
                continue   // system reminders, command output and other injected context
            } else {
                parts.append(text)
            }
        }

        // Pasted photos appear as "[Image #1]" placeholders; the app shows a photo badge instead.
        let text = parts.joined(separator: "\n\n")
            .replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || images > 0 else { return nil }
        return ChatMessage(id: id, kind: .user, text: text, imageCount: images, timestamp: timestamp)
    }

    /// "<command-name>/model</command-name><command-args>opus</command-args>" → "/model opus"
    private static func slashCommand(in text: String) -> String? {
        guard let name = tagContents("command-name", in: text) else { return nil }
        let args = tagContents("command-args", in: text) ?? ""
        let command = name.hasPrefix("/") ? name : "/\(name)"
        return args.isEmpty ? command : "\(command) \(args)"
    }

    private static func tagContents(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayName(forTool name: String) -> String {
        // MCP tools are named mcp__<server>__<tool>; show just the tool.
        if name.hasPrefix("mcp__"), let last = name.components(separatedBy: "__").last { return last }
        return name
    }

    private static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key] as? String { return (path as NSString).abbreviatingWithTildeInPath }
        }
        for key in ["command", "pattern", "url", "query", "description", "prompt", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                let firstLine = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
                return firstLine.count > 120 ? String(firstLine.prefix(117)) + "…" : firstLine
            }
        }
        return ""
    }
}
