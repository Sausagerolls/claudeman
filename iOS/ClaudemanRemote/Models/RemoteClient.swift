import ClaudemanKit
import Foundation

enum RemoteError: LocalizedError {
    case server(String, status: Int)
    case unauthorized(String)
    case badAddress

    var errorDescription: String? {
        switch self {
        case .server(let message, _): message
        case .unauthorized(let message): message
        case .badAddress: "That address isn't valid."
        }
    }
}

/// HTTP client for the Claudeman Mac app's remote-control API.
struct RemoteClient: Sendable {
    let baseURL: URL
    var token: String?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func info() async throws -> ServerInfo {
        try await send("GET", RemoteAPI.Path.info)
    }

    func pair(code: String, deviceName: String) async throws -> PairResponse {
        try await send("POST", RemoteAPI.Path.pair, body: PairRequest(code: code, deviceName: deviceName))
    }

    func status() async throws -> StatusResponse {
        try await send("GET", RemoteAPI.Path.status)
    }

    @discardableResult
    func startSession(projectID: UUID, mode: RemoteLaunchMode) async throws -> SessionResponse {
        try await send("POST", RemoteAPI.Path.projectSessions(projectID), body: LaunchRequest(mode: mode))
    }

    @discardableResult
    func restart(sessionID: UUID, mode: RemoteLaunchMode) async throws -> SessionResponse {
        try await send("POST", RemoteAPI.Path.restart(sessionID), body: LaunchRequest(mode: mode))
    }

    @discardableResult
    func stop(sessionID: UUID) async throws -> SessionResponse {
        try await send("POST", RemoteAPI.Path.stop(sessionID))
    }

    func close(sessionID: UUID) async throws {
        let _: [String: Bool] = try await send("DELETE", RemoteAPI.Path.session(sessionID))
    }

    func chat(sessionID: UUID, after cursor: Int?) async throws -> ChatResponse {
        var path = RemoteAPI.Path.chat(sessionID)
        if let cursor { path += "?after=\(cursor)" }
        return try await send("GET", path)
    }

    func input(sessionID: UUID, _ input: InputRequest) async throws {
        let _: [String: Bool] = try await send("POST", RemoteAPI.Path.input(sessionID), body: input)
    }

    /// Uploads a JPEG and returns its attachment id.
    func uploadImage(sessionID: UUID, jpeg: Data) async throws -> String {
        let response: AttachmentResponse = try await send(
            "POST", RemoteAPI.Path.attachments(sessionID),
            rawBody: jpeg, contentType: "image/jpeg", timeout: 90
        )
        return response.id
    }

    private func send<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await send(method, path, body: Optional<ErrorResponse>.none)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        let data = try body.map { try RemoteAPI.makeEncoder().encode($0) }
        return try await send(method, path, rawBody: data, contentType: data == nil ? nil : "application/json")
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, rawBody: Data?, contentType: String?, timeout: TimeInterval? = nil
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw RemoteError.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let rawBody {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? RemoteAPI.makeDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 401 && path != RemoteAPI.Path.pair { throw RemoteError.unauthorized(message) }
            throw RemoteError.server(message, status: status)
        }
        return try RemoteAPI.makeDecoder().decode(Response.self, from: data)
    }
}
