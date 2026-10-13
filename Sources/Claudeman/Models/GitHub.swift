import Foundation

struct GitHubRepository: Identifiable, Decodable, Hashable {
    let nameWithOwner: String
    let description: String?
    let isPrivate: Bool
    let updatedAt: Date?

    var id: String { nameWithOwner }
    var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
}

enum GitHubError: LocalizedError {
    case invalidRepository
    case destinationExists(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            "Enter a GitHub URL or owner/repo."
        case .destinationExists(let path):
            "A folder already exists at \((path as NSString).abbreviatingWithTildeInPath)."
        case .commandFailed(let message):
            message
        }
    }
}

enum GitHub {
    /// True when the `gh` CLI is installed and logged in.
    static func isCLIReady() async -> Bool {
        await Shell.run("gh auth status").succeeded
    }

    static func listRepositories(limit: Int = 300) async throws -> [GitHubRepository] {
        let result = await Shell.run(
            "gh repo list --limit \"$1\" --json nameWithOwner,description,isPrivate,updatedAt",
            arguments: [String(limit)]
        )
        guard result.succeeded else { throw GitHubError.commandFailed(result.error.trimmed) }

        // Login shells can print banners before the JSON; start at the array.
        let json = result.output.firstIndex(of: "[").map { String(result.output[$0...]) } ?? result.output
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRepository].self, from: Data(json.utf8))
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Accepts `owner/repo`, `https://github.com/owner/repo(.git)`, or `git@github.com:owner/repo.git`.
    /// Returns the clone source and the default folder name.
    static func parse(_ input: String) -> (source: String, name: String)? {
        var text = input.trimmed
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        let isURL = text.contains("://") || text.hasPrefix("git@")
        if text.hasSuffix(".git") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }

        let name = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }

        if isURL { return (input.trimmed, name) }
        let parts = text.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (text, name)
    }

    /// Clones with `gh` when available (handles private repos and auth), otherwise plain `git`.
    static func clone(
        _ input: String,
        into parentDirectory: String,
        folderName: String,
        useGitHubCLI: Bool,
        onStart: ((Process) -> Void)? = nil
    ) async throws -> String {
        guard let parsed = parse(input) else { throw GitHubError.invalidRepository }

        try FileManager.default.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)
        let destination = (parentDirectory as NSString).appendingPathComponent(folderName)
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw GitHubError.destinationExists(destination)
        }

        let result: ShellResult
        if useGitHubCLI {
            result = await Shell.run("exec gh repo clone \"$1\" \"$2\"", arguments: [parsed.source, destination], onStart: onStart)
        } else {
            let source = parsed.source.contains("://") || parsed.source.hasPrefix("git@")
                ? parsed.source
                : "https://github.com/\(parsed.source).git"
            result = await Shell.run("exec git clone \"$1\" \"$2\"", arguments: [source, destination], onStart: onStart)
        }

        guard result.succeeded else {
            let message = result.error.trimmed
            throw GitHubError.commandFailed(message.isEmpty ? "Clone failed (exit code \(result.status))." : message)
        }
        return destination
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
