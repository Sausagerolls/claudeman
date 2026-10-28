import Foundation

public extension RemoteAPI.Path {
    /// GET, with optional `?after=<cursor>`: new transcript messages plus the current screen.
    static func chat(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/chat" }
    /// POST: text and/or keys to type into the session.
    static func input(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/input" }
    /// POST raw image bytes; returns an attachment id to reference in `InputRequest`.
    static func attachments(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/attachments" }
}

public extension RemoteAPI {
    static let maxAttachmentBytes = 20 * 1024 * 1024
}

/// One entry of a session's conversation, simplified from Claude Code's transcript.
public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Something you typed (or a slash command).
        case user
        /// Claude's reply text (Markdown).
        case assistant
        /// A tool Claude used, e.g. "Edit · Sources/App.swift".
        case tool
    }

    public var id: String
    public var kind: Kind
    public var text: String
    /// Tool name for `.tool` messages.
    public var toolName: String?
    /// Number of images attached to a user message.
    public var imageCount: Int
    public var timestamp: Date?

    public init(id: String, kind: Kind, text: String, toolName: String? = nil, imageCount: Int = 0, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.imageCount = imageCount
        self.timestamp = timestamp
    }
}

/// Plain-text copy of the session's visible terminal screen.
public struct ScreenSnapshot: Codable, Hashable, Sendable {
    public var lines: [String]
    public var cols: Int
    public var rows: Int

    public init(lines: [String], cols: Int, rows: Int) {
        self.lines = lines
        self.cols = cols
        self.rows = rows
    }
}

public struct ChatResponse: Codable, Sendable {
    public var session: RemoteSession
    /// Messages after the requested cursor (or the most recent ones on first load).
    public var messages: [ChatMessage]
    /// Pass back as `after` on the next poll.
    public var cursor: Int
    /// True when the client should drop what it has and use `messages` as the full list,
    /// e.g. on first load or when the transcript changed underneath it.
    public var reset: Bool
    /// False until the session's transcript file has been found (shortly after Claude starts).
    public var hasTranscript: Bool
    public var screen: ScreenSnapshot
    /// A question or permission request waiting for an answer, if any.
    public var prompt: PendingPrompt?
    public var activity: SessionActivity?

    public init(session: RemoteSession, messages: [ChatMessage], cursor: Int, reset: Bool, hasTranscript: Bool,
                screen: ScreenSnapshot, prompt: PendingPrompt? = nil, activity: SessionActivity? = nil) {
        self.session = session
        self.messages = messages
        self.cursor = cursor
        self.reset = reset
        self.hasTranscript = hasTranscript
        self.screen = screen
        self.prompt = prompt
        self.activity = activity
    }
}

/// Special keys the phone can press, for answering prompts and navigating menus.
public enum TerminalKey: String, Codable, CaseIterable, Sendable {
    case enter, escape, tab, shiftTab, up, down, left, right, backspace, ctrlC
    case digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9

    public static func digit(_ number: Int) -> TerminalKey? {
        guard (1...9).contains(number) else { return nil }
        return [.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9][number - 1]
    }

    public var bytes: [UInt8] {
        switch self {
        case .enter: [0x0D]
        case .escape: [0x1B]
        case .tab: [0x09]
        case .shiftTab: Array("\u{1B}[Z".utf8)
        case .up: Array("\u{1B}[A".utf8)
        case .down: Array("\u{1B}[B".utf8)
        case .right: Array("\u{1B}[C".utf8)
        case .left: Array("\u{1B}[D".utf8)
        case .backspace: [0x7F]
        case .ctrlC: [0x03]
        case .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
            Array(rawValue.suffix(1).utf8)
        }
    }
}

public struct InputRequest: Codable, Sendable {
    /// Message text. Sent as a paste, then submitted with Enter if `submit` is true.
    public var text: String?
    /// Attachment ids from the attachments endpoint; pasted as file paths so Claude Code attaches them.
    public var attachments: [String]?
    /// Keys pressed after the text, in order.
    public var keys: [TerminalKey]?
    public var submit: Bool

    public init(text: String? = nil, attachments: [String]? = nil, keys: [TerminalKey]? = nil, submit: Bool = false) {
        self.text = text
        self.attachments = attachments
        self.keys = keys
        self.submit = submit
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([String].self, forKey: .attachments)
        keys = try container.decodeIfPresent([TerminalKey].self, forKey: .keys)
        submit = try container.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    }
}

public struct AttachmentResponse: Codable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}
