import Foundation

/// A question, menu or permission request that Claude Code is waiting on, recognised
/// from the terminal screen so the phone can show it as a native card.
public struct PendingPrompt: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        /// Position in the on-screen list, counting every selectable line in order.
        public var index: Int
        /// The option's number on screen ("2." → 2), when it has one.
        public var number: Int?
        public var label: String
        public var detail: String?
        /// The highlighted option (where Enter would land).
        public var isHighlighted: Bool
        /// Checkbox state for multi-select questions; nil for plain options.
        public var isChecked: Bool?
        /// "Type something" options: selecting them lets you type your own answer.
        public var acceptsText: Bool
        /// Options shown below a divider, such as "Chat about this".
        public var isSecondary: Bool

        public init(index: Int, number: Int?, label: String, detail: String?, isHighlighted: Bool,
                    isChecked: Bool?, acceptsText: Bool, isSecondary: Bool) {
            self.index = index
            self.number = number
            self.label = label
            self.detail = detail
            self.isHighlighted = isHighlighted
            self.isChecked = isChecked
            self.acceptsText = acceptsText
            self.isSecondary = isSecondary
        }
    }

    public struct Step: Codable, Hashable, Sendable {
        public var label: String
        public var isDone: Bool

        public init(label: String, isDone: Bool) {
            self.label = label
            self.isDone = isDone
        }
    }

    /// Changes whenever the question or its options change, so stale taps can be rejected.
    public var id: String
    /// Heading above the question, e.g. "Bash command".
    public var title: String?
    /// Explanatory text between the heading and the question.
    public var detail: String?
    /// Command or file content shown in a dashed box (permission prompts).
    public var code: String?
    public var question: String
    public var options: [Option]
    /// Tabs for multi-question forms ("Size", "Toppings", "Submit").
    public var steps: [Step]

    public var isMultiSelect: Bool { options.contains { $0.isChecked != nil } }

    public init(id: String, title: String?, detail: String?, code: String?, question: String, options: [Option], steps: [Step]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.code = code
        self.question = question
        self.options = options
        self.steps = steps
    }
}

/// What Claude is doing right now, from the status line ("✻ Brewing… (3s · esc to interrupt)").
public struct SessionActivity: Codable, Hashable, Sendable {
    public var isWorking: Bool
    /// The status word, e.g. "Brewing…".
    public var label: String?

    public init(isWorking: Bool, label: String?) {
        self.isWorking = isWorking
        self.label = label
    }
}

public struct AnswerRequest: Codable, Sendable {
    public var promptID: String
    public var optionIndex: Int
    /// Your own answer, for options that accept text.
    public var text: String?

    public init(promptID: String, optionIndex: Int, text: String? = nil) {
        self.promptID = promptID
        self.optionIndex = optionIndex
        self.text = text
    }
}

public extension RemoteAPI.Path {
    /// POST an `AnswerRequest` for the session's current prompt.
    static func answer(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/answer" }
}

/// Reads Claude Code's terminal screen. Pure text processing, so it can be tested on captured screens.
public enum ScreenReader {
    private static let cursor: Character = "❯"

    // MARK: Activity

    public static func activity(in lines: [String]) -> SessionActivity {
        let tail = lines.suffix(8)
        let working = tail.contains { $0.localizedCaseInsensitiveContains("esc to interrupt") }
        guard working else { return SessionActivity(isWorking: false, label: nil) }

        // Status line: a spinner glyph, then a word ending in "…".
        var label: String?
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, !first.isLetter, !first.isNumber, first != cursor,
                  let ellipsis = trimmed.firstIndex(of: "…") else { continue }
            let word = trimmed[trimmed.index(after: trimmed.startIndex)..<trimmed.index(after: ellipsis)]
                .trimmingCharacters(in: .whitespaces)
            if !word.isEmpty, word.count < 40 { label = word; break }
        }
        return SessionActivity(isWorking: true, label: label)
    }

    // MARK: Prompts

    public static func prompt(in rawLines: [String]) -> PendingPrompt? {
        var lines = rawLines.map {
            $0.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{0}", with: " ")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }

        // 1. A selection menu ends with a key-hint footer. When the menu fills the screen the
        //    footer can be cut off, so a numbered option list at the very bottom also counts.
        //    (The normal input box always has rules and a status line below it.)
        let footer: Int
        if let hint = lines.indices.reversed().prefix(4).first(where: { isFooter(lines[$0]) }) {
            footer = hint
        } else if lines.indices.reversed().prefix(3).contains(where: { parseOption(lines[$0])?.number != nil }) {
            footer = lines.count
        } else {
            return nil
        }

        // 2. Survey the list: where labels start, and whether options are numbered or checkboxes.
        let window = max(0, footer - 40)..<footer
        guard let anchor = window.reversed().first(where: { parseOption(lines[$0])?.highlighted == true }),
              let labelColumn = parseOption(lines[anchor])?.column else { return nil }
        let numbered = window.compactMap { parseOption(lines[$0]) }.filter { $0.number != nil }
        let hasNumbers = !numbered.isEmpty
        let hasCheckboxes = numbered.contains { $0.label.hasPrefix("[") }
        // Unnumbered lines at the label column are items ("Submit", trust-prompt choices) in
        // unnumbered or checkbox lists; in numbered lists they are option descriptions.
        let bareLinesAreItems = !hasNumbers || hasCheckboxes

        // 3. Walk up from the footer collecting options.
        struct Item { var line: Int; var number: Int?; var label: String; var highlighted: Bool; var details: [String]; var secondary: Bool }
        var items: [Item] = []
        var pendingDetails: [String] = []
        var sawDivider = false
        var questionEnd: Int?

        var index = footer - 1
        while index >= 0 {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if !items.isEmpty { questionEnd = index - 1; break }
                index -= 1; continue
            }
            if isRule(trimmed) {
                if items.isEmpty { sawDivider = true }   // divider between main and secondary options
                else if index > anchor { sawDivider = true }
                else { break }                           // top edge of the panel: no question line
                index -= 1; continue
            }

            if let option = parseOption(line) {
                items.append(Item(line: index, number: option.number, label: option.label, highlighted: option.highlighted,
                                  details: pendingDetails.reversed(), secondary: false))
                pendingDetails = []
                index -= 1; continue
            }

            let indent = line.prefix { $0 == " " }.count
            if indent > labelColumn || (indent == labelColumn && !bareLinesAreItems) {
                pendingDetails.append(trimmed)
                index -= 1; continue
            }
            if indent == labelColumn {
                items.append(Item(line: index, number: nil, label: trimmed, highlighted: false,
                                  details: pendingDetails.reversed(), secondary: false))
                pendingDetails = []
                index -= 1; continue
            }

            // Anything less indented is the question.
            questionEnd = index
            break
        }

        guard !items.isEmpty, items.contains(where: \.highlighted) else { return nil }
        items.reverse()

        // Options after a divider (e.g. "Chat about this") are secondary.
        if sawDivider, let dividerLine = (items.first!.line...items.last!.line).first(where: { isRule(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            for i in items.indices where items[i].line > dividerLine { items[i].secondary = true }
        }

        // 4. The question: contiguous text lines above the options.
        var question: [String] = []
        var cursorLine = questionEnd ?? -1
        while cursorLine >= 0 {
            let trimmed = lines[cursorLine].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isRule(trimmed) || isTabHeader(trimmed) { break }
            question.insert(trimmed, at: 0)
            cursorLine -= 1
        }

        // 5. Heading, details and code: everything between the panel's top rule and the question.
        var header: [String] = []
        var line = cursorLine
        while line >= 0 {
            let trimmed = lines[line].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("──") { break }
            header.insert(lines[line], at: 0)
            line -= 1
        }

        var steps: [PendingPrompt.Step] = []
        var title: String?
        var detail: [String] = []
        var code: [String] = []
        var inCode = false
        var inTip = false
        for raw in header {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if isTabHeader(trimmed) { steps = parseSteps(trimmed); continue }
            if trimmed.hasPrefix("╌") { inCode.toggle(); continue }
            if trimmed.isEmpty { inTip = false; continue }
            if inCode { code.append(trimmed); continue }
            // Skip "Tip: …" hints, including their wrapped continuation lines.
            if trimmed.hasPrefix("Tip:") { inTip = true; continue }
            if inTip, trimmed.first?.isLowercase == true { continue }
            inTip = false
            if title == nil { title = trimmed } else { detail.append(trimmed) }
        }

        let options = items.enumerated().map { position, item -> PendingPrompt.Option in
            var label = item.label
            var checked: Bool?
            if label.hasPrefix("[ ]") { checked = false; label = String(label.dropFirst(3)) }
            else if label.hasPrefix("[✔]") || label.hasPrefix("[x]") || label.hasPrefix("[✓]") { checked = true; label = String(label.dropFirst(3)) }
            label = label.trimmingCharacters(in: .whitespaces)
            let plain = label.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return PendingPrompt.Option(
                index: position,
                number: item.number,
                label: label,
                detail: item.details.isEmpty ? nil : item.details.joined(separator: " "),
                isHighlighted: item.highlighted,
                isChecked: checked,
                acceptsText: plain == "type something" || plain == "other",
                isSecondary: item.secondary
            )
        }

        let questionText = question.joined(separator: " ")
        let titleText = title.flatMap { $0 == questionText ? nil : $0 }
        let identity = ([titleText ?? "", questionText] + options.map { "\($0.label)|\($0.isChecked.map(String.init) ?? "")" }).joined(separator: "\n")
        return PendingPrompt(
            id: String(format: "%08x", stableHash(identity)),
            title: titleText,
            detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
            code: code.isEmpty ? nil : code.joined(separator: "\n"),
            question: questionText.isEmpty ? (titleText ?? "Choose an option") : questionText,
            options: options,
            steps: steps
        )
    }

    /// Keys that choose `option` in `prompt`: its number when it has one (Claude Code selects
    /// or toggles directly), otherwise arrow keys from the highlighted row, then Enter.
    public static func keys(toChoose option: PendingPrompt.Option, in prompt: PendingPrompt) -> [TerminalKey] {
        if let number = option.number, let key = TerminalKey.digit(number), !option.acceptsText {
            return [key]
        }
        return navigationKeys(to: option, in: prompt) + [.enter]
    }

    /// Arrow keys that move the highlight onto `option`.
    public static func navigationKeys(to option: PendingPrompt.Option, in prompt: PendingPrompt) -> [TerminalKey] {
        let current = prompt.options.first(where: \.isHighlighted)?.index ?? 0
        let delta = option.index - current
        return Array(repeating: delta > 0 ? TerminalKey.down : .up, count: abs(delta))
    }

    // MARK: Helpers

    private static func isFooter(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("esc to cancel") || lower.contains("enter to select") || lower.contains("enter to confirm")
            || lower.contains("to navigate")
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return false }
        return (first == "─" || first == "╌" || first == "━") && trimmed.allSatisfy { $0 == first }
    }

    private static func isTabHeader(_ trimmed: String) -> Bool {
        trimmed.contains("☐") || trimmed.contains("☒") || (trimmed.contains("✔") && trimmed.contains("Submit"))
    }

    private static func parseSteps(_ header: String) -> [PendingPrompt.Step] {
        var steps: [PendingPrompt.Step] = []
        var current: (mark: Character, text: String)?
        for character in header {
            if "☐☒✔".contains(character) {
                if let current { steps.append(.init(label: current.text.trimmingCharacters(in: .whitespaces), isDone: current.mark != "☐")) }
                current = (character, "")
            } else if character == "←" || character == "→" {
                continue
            } else if current != nil {
                current!.text.append(character)
            }
        }
        if let current { steps.append(.init(label: current.text.trimmingCharacters(in: .whitespaces), isDone: current.mark != "☐")) }
        // The trailing "✔ Submit" tab is the review step, not a question.
        return steps.filter { !$0.label.isEmpty && $0.label != "Submit" }
    }

    private static func parseOption(_ line: String) -> (column: Int, number: Int?, label: String, highlighted: Bool)? {
        var rest = Substring(line)
        var column = 0
        while rest.first == " " { rest.removeFirst(); column += 1 }
        var highlighted = false
        if rest.first == cursor {
            highlighted = true
            rest.removeFirst(); column += 1
            while rest.first == " " { rest.removeFirst(); column += 1 }
        }
        // Numbered: "12. Label"
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            let label = rest.dropFirst(digits.count + 2)
            let labelColumn = column + digits.count + 2
            return (labelColumn, Int(digits), label.trimmingCharacters(in: .whitespaces), highlighted)
        }
        // Unnumbered but highlighted: "❯ Yes, I trust this folder"
        if highlighted, !rest.isEmpty {
            return (column, nil, rest.trimmingCharacters(in: .whitespaces), true)
        }
        return nil
    }

    /// FNV-1a; Swift's `hashValue` is randomised per process.
    private static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
