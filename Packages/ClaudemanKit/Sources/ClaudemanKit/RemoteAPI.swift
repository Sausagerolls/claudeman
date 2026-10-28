import Foundation

/// Wire format shared by the Claudeman Mac app (server) and the iOS companion (client).
///
/// Transport is plain HTTP/1.1 with JSON bodies. Every endpoint except `pair` and `info`
/// requires `Authorization: Bearer <token>`, where the token comes from pairing.
public enum RemoteAPI {
    public static let bonjourType = "_claudeman._tcp"
    public static let defaultPort: UInt16 = 47821
    public static let version = 1

    public enum Path {
        public static let info = "/api/info"
        public static let pair = "/api/pair"
        public static let status = "/api/status"
        public static func projectSessions(_ projectID: UUID) -> String { "/api/projects/\(projectID.uuidString)/sessions" }
        public static func restart(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/restart" }
        public static func stop(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)/stop" }
        public static func session(_ sessionID: UUID) -> String { "/api/sessions/\(sessionID.uuidString)" }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// How a session is launched remotely. `resume` is left out on purpose: its picker
/// needs someone at the keyboard.
public enum RemoteLaunchMode: String, Codable, CaseIterable, Sendable {
    case new
    case continueLast

    public var title: String {
        switch self {
        case .new: "New Session"
        case .continueLast: "Continue Last Session"
        }
    }
}

public struct ServerInfo: Codable, Sendable {
    public var name: String
    public var apiVersion: Int
    public var appVersion: String

    public init(name: String, apiVersion: Int, appVersion: String) {
        self.name = name
        self.apiVersion = apiVersion
        self.appVersion = appVersion
    }
}

public struct PairRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

public struct PairResponse: Codable, Sendable {
    public var token: String
    public var server: ServerInfo

    public init(token: String, server: ServerInfo) {
        self.token = token
        self.server = server
    }
}

public struct LaunchRequest: Codable, Sendable {
    public var mode: RemoteLaunchMode

    public init(mode: RemoteLaunchMode) {
        self.mode = mode
    }
}

public struct StatusResponse: Codable, Sendable {
    public var server: ServerInfo
    public var projects: [RemoteProject]

    public init(server: ServerInfo, projects: [RemoteProject]) {
        self.server = server
        self.projects = projects
    }
}

public struct RemoteProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var folderExists: Bool
    public var lastOpenedAt: Date?
    public var sessions: [RemoteSession]

    public init(id: UUID, name: String, path: String, folderExists: Bool, lastOpenedAt: Date?, sessions: [RemoteSession]) {
        self.id = id
        self.name = name
        self.path = path
        self.folderExists = folderExists
        self.lastOpenedAt = lastOpenedAt
        self.sessions = sessions
    }

    public var runningCount: Int { sessions.filter(\.isRunning).count }
}

public struct RemoteSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Terminal title set by Claude Code, usually a short summary of the current task.
    public var title: String
    public var isRunning: Bool
    public var exitCode: Int32?
    public var startedAt: Date

    public init(id: UUID, name: String, title: String, isRunning: Bool, exitCode: Int32?, startedAt: Date) {
        self.id = id
        self.name = name
        self.title = title
        self.isRunning = isRunning
        self.exitCode = exitCode
        self.startedAt = startedAt
    }
}

public struct SessionResponse: Codable, Sendable {
    public var session: RemoteSession

    public init(session: RemoteSession) {
        self.session = session
    }
}

public struct ErrorResponse: Codable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}
