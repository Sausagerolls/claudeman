import AppKit
import SwiftTerm

/// Terminal colour scheme: background, foreground, cursor, selection and the 16 ANSI colours.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// black, red, green, yellow, blue, magenta, cyan, white, then the 8 bright variants.
    let ansi: [String]

    static let automaticID = "automatic"

    static func resolve(_ id: String, isDark: Bool) -> TerminalTheme {
        if id != automaticID, let theme = all.first(where: { $0.id == id }) {
            return theme
        }
        return isDark ? .claudemanDark : .claudemanLight
    }

    func apply(to view: TerminalView) {
        view.nativeBackgroundColor = NSColor(hex: background)
        view.nativeForegroundColor = NSColor(hex: foreground)
        view.caretColor = NSColor(hex: cursor)
        view.selectedTextBackgroundColor = NSColor(hex: selection)
        view.installColors(ansi.map(SwiftTerm.Color.init(hex:)))
    }

    static let all: [TerminalTheme] = [
        .claudemanDark, .claudemanLight, .solarizedDark, .solarizedLight, .dracula, .nord, .gruvboxDark, .oneDark,
    ]

    static let claudemanDark = TerminalTheme(
        id: "claudeman-dark", name: "Claudeman Dark", isDark: true,
        background: "1C1C1E", foreground: "E6E6E6", cursor: "D97757", selection: "4A3A33",
        ansi: ["1C1C1E", "FF6B6B", "8BD17C", "E5C07B", "6CA6F0", "C792EA", "56C8D8", "D0D0D0",
               "5C5C66", "FF8A8A", "A6E39A", "F2D492", "8FBCFF", "DDB0F5", "7FDCEB", "FFFFFF"]
    )

    static let claudemanLight = TerminalTheme(
        id: "claudeman-light", name: "Claudeman Light", isDark: false,
        background: "FAF9F5", foreground: "2B2B2B", cursor: "C15F3C", selection: "F0D9CC",
        ansi: ["2B2B2B", "C0392B", "2E8B57", "B8860B", "2F6FD0", "8E44AD", "16818F", "D6D6D6",
               "707070", "E74C3C", "3CB371", "D4A017", "4A8BEA", "A55BC4", "1FA3B5", "FFFFFF"]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        background: "002B36", foreground: "839496", cursor: "93A1A1", selection: "073642",
        ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
               "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: "FDF6E3", foreground: "657B83", cursor: "586E75", selection: "EEE8D5",
        ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
               "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", isDark: true,
        background: "282A36", foreground: "F8F8F2", cursor: "F8F8F2", selection: "44475A",
        ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
               "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord", isDark: true,
        background: "2E3440", foreground: "D8DEE9", cursor: "D8DEE9", selection: "434C5E",
        ansi: ["3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0",
               "4C566A", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "8FBCBB", "ECEFF4"]
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
        background: "282828", foreground: "EBDBB2", cursor: "EBDBB2", selection: "504945",
        ansi: ["282828", "CC241D", "98971A", "D79921", "458588", "B16286", "689D6A", "A89984",
               "928374", "FB4934", "B8BB26", "FABD2F", "83A598", "D3869B", "8EC07C", "EBDBB2"]
    )

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", isDark: true,
        background: "282C34", foreground: "ABB2BF", cursor: "528BFF", selection: "3E4451",
        ansi: ["282C34", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "ABB2BF",
               "5C6370", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "FFFFFF"]
    )
}

private func rgb(_ hex: String) -> (UInt16, UInt16, UInt16) {
    let value = UInt32(hex, radix: 16) ?? 0
    return (UInt16((value >> 16) & 0xFF), UInt16((value >> 8) & 0xFF), UInt16(value & 0xFF))
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = rgb(hex)
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension SwiftTerm.Color {
    convenience init(hex: String) {
        let (r, g, b) = rgb(hex)
        self.init(red8: r, green8: g, blue8: b)
    }
}
