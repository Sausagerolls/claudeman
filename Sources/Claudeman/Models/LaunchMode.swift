import Foundation

/// How a Claude Code session is started, mapped onto `claude` CLI flags.
enum LaunchMode: String, CaseIterable, Identifiable {
    case new
    case continueLast
    case resume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "New Session"
        case .continueLast: "Continue Last Session"
        case .resume: "Resume Session…"
        }
    }

    var systemImage: String {
        switch self {
        case .new: "plus"
        case .continueLast: "arrow.uturn.forward"
        case .resume: "clock.arrow.circlepath"
        }
    }

    var arguments: [String] {
        switch self {
        case .new: []
        case .continueLast: ["--continue"]
        case .resume: ["--resume"]
        }
    }
}
