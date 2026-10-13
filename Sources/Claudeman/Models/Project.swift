import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var createdAt = Date()
    var lastOpenedAt: Date?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Path with the home directory shortened to `~`, for display.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
