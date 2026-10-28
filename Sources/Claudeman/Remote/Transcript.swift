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

    /// Where each image in `messages` comes from, by `ChatImage.id`.
    private(set) var images: [String: ImageSource] = [:]

    enum ImageSource {
        /// Embedded in the transcript, as Claude Code stores pasted images and image tool results.
        case inline(mediaType: String, base64: String)
        /// A file on disk that Claude wrote or mentioned.
        case file(String)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

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
            images = [:]
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
            messages += parse(object)
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

    private func parse(_ record: [String: Any]) -> [ChatMessage] {
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return [] }

        let id = record["uuid"] as? String ?? UUID().uuidString
        let timestamp = (record["timestamp"] as? String).flatMap(Self.isoFormatter.date(from:))

        if type == "user" {
            return userMessages(id: id, content: message["content"], timestamp: timestamp)
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var result: [ChatMessage] = []
        for (index, block) in blocks.enumerated() {
            let blockID = "\(id)-\(index)"
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Images Claude mentions by path ("Saved the chart to /tmp/chart.png").
                let mentioned = Self.imagePaths(in: text).enumerated().map { n, path in
                    registerFile(path, id: "\(blockID)-m\(n)")
                }
                result.append(ChatMessage(id: blockID, kind: .assistant, text: text, timestamp: timestamp,
                                          images: mentioned.isEmpty ? nil : mentioned))
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let name = Self.displayName(forTool: block["name"] as? String ?? "Tool")
                result.append(ChatMessage(id: blockID, kind: .tool, text: Self.toolSummary(input), toolName: name, timestamp: timestamp))
                // An image Claude creates: show it once the file exists.
                if ["Write", "Edit", "MultiEdit"].contains(block["name"] as? String ?? ""),
                   let path = input["file_path"] as? String, Self.isImagePath(path) {
                    let image = registerFile(path, id: "\(blockID)-f")
                    result.append(ChatMessage(id: "\(blockID)-file", kind: .assistant, text: "", timestamp: timestamp, images: [image]))
                }
            default:
                continue
            }
        }
        return result
    }

    private func userMessages(id: String, content: Any?, timestamp: Date?) -> [ChatMessage] {
        var texts: [String] = []
        var attached: [ChatImage] = []
        var results: [ChatMessage] = []

        if let string = content as? String {
            texts.append(string)
        } else if let blocks = content as? [[String: Any]] {
            for (index, block) in blocks.enumerated() {
                switch block["type"] as? String {
                case "text":
                    texts.append(block["text"] as? String ?? "")
                case "image":
                    if let image = registerInline(block, id: "\(id)-i\(index)") { attached.append(image) }
                case "tool_result":
                    // Images a tool returned to Claude (screenshots, image files it read) are shown
                    // on Claude's side; other tool output appears through the tool call instead.
                    let parts = block["content"] as? [[String: Any]] ?? []
                    let shown = parts.enumerated().compactMap { n, part in
                        part["type"] as? String == "image" ? registerInline(part, id: "\(id)-r\(index)-\(n)") : nil
                    }
                    if !shown.isEmpty {
                        results.append(ChatMessage(id: "\(id)-r\(index)", kind: .assistant, text: "", timestamp: timestamp, images: shown))
                    }
                default:
                    break
                }
            }
        }

        var parts: [String] = []
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let command = Self.slashCommand(in: text) {
                parts.append(command)
            } else if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("Caveat:") || text.hasPrefix("[Image: source:") {
                continue   // system reminders, command output, image source notes and other injected context
            } else {
                parts.append(text)
            }
        }

        // Pasted photos appear as "[Image #1]" placeholders; the app shows the photos instead.
        let text = parts.joined(separator: "\n\n")
            .replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || !attached.isEmpty {
            results.insert(ChatMessage(id: id, kind: .user, text: text, imageCount: attached.count, timestamp: timestamp,
                                       images: attached.isEmpty ? nil : attached), at: 0)
        }
        return results
    }

    // MARK: Images

    private func registerInline(_ block: [String: Any], id: String) -> ChatImage? {
        guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
              let data = source["data"] as? String else { return nil }
        let mediaType = source["media_type"] as? String ?? "image/png"
        images[id] = .inline(mediaType: mediaType, base64: data)
        let ext = mediaType.split(separator: "/").last.map(String.init) ?? "png"
        return ChatImage(id: id, name: "image.\(ext == "jpeg" ? "jpg" : ext)")
    }

    private func registerFile(_ path: String, id: String) -> ChatImage {
        images[id] = .file((path as NSString).expandingTildeInPath)
        return ChatImage(id: id, name: (path as NSString).lastPathComponent)
    }

    /// Returns an image's bytes and MIME type, or nil if it's unknown or the file is gone.
    func imageData(id: String) -> (data: Data, mediaType: String)? {
        switch images[id] {
        case .inline(let mediaType, let base64):
            return Data(base64Encoded: base64).map { ($0, mediaType) }
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 25 * 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            let ext = url.pathExtension.lowercased()
            let mediaType = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
            return (data, mediaType)
        case nil:
            return nil
        }
    }

    private static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Absolute or ~ paths to existing image files mentioned in text.
    private static func imagePaths(in text: String) -> [String] {
        let pattern = #"(?:~|/)[^\s`'"()<>\[\]]+\.(?:png|jpe?g|gif|webp|heic)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let path = String(text[r])
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded), seen.insert(expanded).inserted else { return nil }
            return path
        }
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
        if name == "AskUserQuestion" { return "Question" }
        // MCP tools are named mcp__<server>__<tool>; show just the tool.
        if name.hasPrefix("mcp__"), let last = name.components(separatedBy: "__").last { return last }
        return name
    }

    private static func toolSummary(_ input: [String: Any]) -> String {
        // AskUserQuestion: show the question itself.
        if let questions = input["questions"] as? [[String: Any]], let first = questions.first?["question"] as? String {
            return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
        }
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
