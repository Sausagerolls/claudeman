import AppKit
import ClaudemanKit
import CryptoKit
import Foundation

struct PairedDevice: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// SHA-256 of the bearer token; the token itself is never stored on the Mac.
    var tokenHash: String
    var pairedAt = Date()
    var lastSeenAt: Date?
}

/// Owns the remote-control server, pairing and the list of paired iPhones/iPads.
@MainActor
final class RemoteAccess: ObservableObject {
    static let shared = RemoteAccess()

    static let pairingLifetime: TimeInterval = 5 * 60
    static let maxPairingAttempts = 5

    @Published private(set) var state: HTTPServer.State = .stopped
    @Published private(set) var devices: [PairedDevice] = [] {
        didSet { saveDevices() }
    }
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?

    private var transcripts: [UUID: TranscriptReader] = [:]
    /// Uploaded photos by attachment id → file path.
    private var attachments: [String: String] = [:]
    private var failedPairingAttempts = 0
    private var runningPort: UInt16?
    private let devicesKey = "remoteDevices"

    private lazy var server = HTTPServer(
        handler: { request in await RemoteAccess.shared.handle(request) },
        onStateChange: { state in Task { @MainActor in RemoteAccess.shared.state = state } }
    )

    private init() {
        if let data = UserDefaults.standard.data(forKey: devicesKey) {
            devices = (try? RemoteAPI.makeDecoder().decode([PairedDevice].self, from: data)) ?? []
        }
    }

    var serviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    var serverInfo: ServerInfo {
        ServerInfo(
            name: serviceName,
            apiVersion: RemoteAPI.version,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }

    // MARK: Lifecycle

    /// Starts, restarts or stops the server to match the current settings.
    /// Called on every defaults change, so it must be a no-op when nothing relevant changed.
    /// `runningPort` is the port we asked for (set synchronously); `state` arrives later.
    func applySettings() {
        let defaults = UserDefaults.standard
        if defaults.remoteEnabled {
            guard runningPort != defaults.remotePort else { return }
            runningPort = defaults.remotePort
            server.start(port: defaults.remotePort, serviceName: serviceName)
        } else if runningPort != nil {
            runningPort = nil
            cancelPairing()
            server.stop()
        }
    }

    /// Tries again after a failure such as the port being in use by another app.
    func retry() {
        guard let port = runningPort else { return applySettings() }
        server.stop()
        // Give the cancelled listener a moment to release the port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.server.start(port: port, serviceName: self.serviceName)
            }
        }
    }

    // MARK: Pairing

    func beginPairing() {
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
        failedPairingAttempts = 0
    }

    func cancelPairing() {
        pairingCode = nil
        pairingExpiresAt = nil
    }

    func revoke(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
    }

    private func pair(_ request: PairRequest) -> HTTPResponse {
        guard let code = pairingCode, let expiry = pairingExpiresAt, expiry > Date() else {
            cancelPairing()
            return .error("No pairing in progress. Click “Pair Device…” in Claudeman’s Remote settings.", status: 403)
        }
        guard request.code.trimmingCharacters(in: .whitespaces) == code else {
            failedPairingAttempts += 1
            if failedPairingAttempts >= Self.maxPairingAttempts {
                cancelPairing()
                return .error("Too many wrong codes. Start pairing again on the Mac.", status: 429)
            }
            return .error("Wrong pairing code.", status: 401)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return .error("Could not generate a token.", status: 500)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let name = request.deviceName.trimmingCharacters(in: .whitespaces)
        devices.append(PairedDevice(name: name.isEmpty ? "iOS device" : String(name.prefix(64)), tokenHash: Self.hash(token)))
        cancelPairing()
        return .json(PairResponse(token: token, server: serverInfo), status: 201)
    }

    private func authenticate(_ request: HTTPRequest) -> Bool {
        guard let token = request.bearerToken, !token.isEmpty else { return false }
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return false }
        // Only persist "last seen" occasionally; the app polls every few seconds.
        if (devices[index].lastSeenAt.map { Date().timeIntervalSince($0) > 60 }) ?? true {
            devices[index].lastSeenAt = Date()
        }
        return true
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func saveDevices() {
        if let data = try? RemoteAPI.makeEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
    }

    // MARK: Routing

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)   // ["api", ...]
        guard parts.first == "api" else { return .error("Not found.", status: 404) }
        let route = Array(parts.dropFirst())

        if request.method == "GET", route == ["info"] {
            return .json(serverInfo)
        }
        if request.method == "POST", route == ["pair"] {
            guard let body = decode(PairRequest.self, request) else { return .error("Invalid body.", status: 400) }
            return pair(body)
        }

        guard authenticate(request) else { return .error("Not paired, or this device was removed.", status: 401) }
        let model = AppModel.shared

        if request.method == "GET", route == ["status"] {
            return .json(status())
        }

        if request.method == "POST", let id = Self.match(route, "projects", nil, "sessions") {
            guard let project = model.project(id: id) else { return .error("Project not found.", status: 404) }
            guard project.folderExists else { return .error("The project folder no longer exists.", status: 409) }
            let mode = decode(LaunchRequest.self, request)?.mode ?? .new
            guard let session = model.openSession(for: project, mode: LaunchMode(mode), select: false) else {
                return .error("Could not start a session.", status: 409)
            }
            return .json(SessionResponse(session: session.remote), status: 201)
        }

        if request.method == "POST", let id = Self.match(route, "sessions", nil, "restart") {
            guard let old = model.session(id: id) else { return .error("Session not found.", status: 404) }
            let mode = decode(LaunchRequest.self, request)?.mode ?? .continueLast
            guard let session = model.restart(old, mode: LaunchMode(mode), select: false) else {
                return .error("Could not restart the session.", status: 409)
            }
            return .json(SessionResponse(session: session.remote), status: 201)
        }

        if request.method == "POST", let id = Self.match(route, "sessions", nil, "stop") {
            guard let session = model.session(id: id) else { return .error("Session not found.", status: 404) }
            session.terminate()
            return .json(SessionResponse(session: session.remote))
        }

        if request.method == "GET", let id = Self.match(route, "sessions", nil, "chat") {
            guard let session = model.session(id: id) else { return .error("Session not found.", status: 404) }
            return .json(chat(for: session, after: request.query["after"].flatMap(Int.init)))
        }

        if request.method == "POST", let id = Self.match(route, "sessions", nil, "input") {
            guard let session = model.session(id: id) else { return .error("Session not found.", status: 404) }
            guard session.isRunning else { return .error("This session has ended. Continue it first.", status: 409) }
            guard let input = decode(InputRequest.self, request) else { return .error("Invalid body.", status: 400) }
            return await type(input, into: session)
        }

        if request.method == "POST", let id = Self.match(route, "sessions", nil, "answer") {
            guard let session = model.session(id: id) else { return .error("Session not found.", status: 404) }
            guard let answer = decode(AnswerRequest.self, request) else { return .error("Invalid body.", status: 400) }
            return await self.answer(answer, in: session)
        }

        if request.method == "POST", let id = Self.match(route, "sessions", nil, "attachments") {
            guard model.session(id: id) != nil else { return .error("Session not found.", status: 404) }
            return saveAttachment(request)
        }

        if request.method == "DELETE", let id = Self.match(route, "sessions", nil) {
            guard let session = model.session(id: id) else { return .error("Session not found.", status: 404) }
            model.close(session)
            return .json(["ok": true])
        }

        return .error("Not found.", status: 404)
    }

    /// Matches `route` against a pattern where `nil` marks the one UUID segment, and returns that UUID.
    private static func match(_ route: [String], _ pattern: String?...) -> UUID? {
        guard route.count == pattern.count else { return nil }
        var captured: UUID?
        for (segment, expected) in zip(route, pattern) {
            if let expected {
                guard segment == expected else { return nil }
            } else {
                guard let id = UUID(uuidString: segment) else { return nil }
                captured = id
            }
        }
        return captured
    }

    // MARK: Chat

    private func chat(for session: TerminalSession, after cursor: Int?) -> ChatResponse {
        let reader = transcriptReader(for: session)
        reader?.refresh()
        let messages = reader?.messages ?? []
        let generation = reader?.generation ?? 0

        // The cursor packs the reader generation with the message count, so a rewritten
        // transcript makes the client start over instead of skipping messages.
        var slice: [ChatMessage]
        var reset = true
        if let cursor, cursor >> 32 == generation, Int(cursor & 0xFFFF_FFFF) <= messages.count {
            slice = Array(messages[Int(cursor & 0xFFFF_FFFF)...])
            reset = false
        } else {
            slice = Array(messages.suffix(300))
        }

        let screen = session.screen()
        return ChatResponse(
            session: session.remote,
            messages: slice,
            cursor: generation << 32 | messages.count,
            reset: reset,
            hasTranscript: reader != nil,
            screen: screen,
            prompt: session.isRunning ? ScreenReader.prompt(in: screen.lines) : nil,
            activity: session.isRunning ? ScreenReader.activity(in: screen.lines) : nil
        )
    }

    private func transcriptReader(for session: TerminalSession) -> TranscriptReader? {
        let live = Set(AppModel.shared.sessions.map(\.id))
        transcripts = transcripts.filter { live.contains($0.key) }
        if let reader = transcripts[session.id] { return reader }

        if session.claudeSessionID == nil {
            session.claudeSessionID = discoverTranscript(for: session)
        }
        guard let sessionID = session.claudeSessionID else { return nil }
        let url = TranscriptReader.transcriptURL(projectPath: session.projectPath, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let reader = TranscriptReader(url: url)
        transcripts[session.id] = reader
        return reader
    }

    /// For continued or resumed sessions we don't know Claude's session id up front:
    /// pick the newest transcript in the project that no other open session has claimed.
    private func discoverTranscript(for session: TerminalSession) -> String? {
        let claimed = Set(AppModel.shared.sessions.filter { $0.id != session.id }.compactMap(\.claudeSessionID))
        let candidates = TranscriptReader.transcripts(projectPath: session.projectPath).filter { !claimed.contains($0.id) }
        switch session.mode {
        case .new:
            return nil
        case .continueLast:
            return candidates.first?.id
        case .resume:
            // Wait until the picked conversation is written to after the session started.
            return candidates.first { $0.modified >= session.startedAt.addingTimeInterval(-2) }?.id
        }
    }

    /// Chooses an option in the prompt currently on screen. The prompt id must still match,
    /// so a tap on a question that has since changed can't pick the wrong thing.
    private func answer(_ answer: AnswerRequest, in session: TerminalSession) async -> HTTPResponse {
        guard let prompt = ScreenReader.prompt(in: session.screen().lines), prompt.id == answer.promptID else {
            return .error("That question is no longer showing.", status: 409)
        }
        guard let option = prompt.options.first(where: { $0.index == answer.optionIndex }) else {
            return .error("Unknown option.", status: 400)
        }

        if option.acceptsText, let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            for key in ScreenReader.navigationKeys(to: option, in: prompt) {
                session.press(key)
                try? await Task.sleep(for: .milliseconds(40))
            }
            await session.send(text: text, imagePaths: [], submit: true)
        } else {
            for key in ScreenReader.keys(toChoose: option, in: prompt) {
                session.press(key)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        return .json(["ok": true])
    }

    private func type(_ input: InputRequest, into session: TerminalSession) async -> HTTPResponse {
        var paths: [String] = []
        for id in input.attachments ?? [] {
            guard let path = attachments[id] else { return .error("Attachment expired. Attach the photo again.", status: 400) }
            paths.append(path)
        }
        await session.send(text: input.text ?? "", imagePaths: paths, submit: input.submit)
        for key in input.keys ?? [] {
            session.press(key)
            try? await Task.sleep(for: .milliseconds(40))
        }
        return .json(["ok": true])
    }

    /// Saves an uploaded photo where Claude Code can read it. The folder path has no spaces,
    /// so the pasted path is recognised as an image and attached.
    private func saveAttachment(_ request: HTTPRequest) -> HTTPResponse {
        let type = request.headers["content-type"]?.lowercased() ?? ""
        let ext: String
        switch type {
        case let t where t.hasPrefix("image/jpeg"): ext = "jpg"
        case let t where t.hasPrefix("image/png"): ext = "png"
        case let t where t.hasPrefix("image/gif"): ext = "gif"
        case let t where t.hasPrefix("image/webp"): ext = "webp"
        default: return .error("Only JPEG, PNG, GIF and WebP images can be attached.", status: 400)
        }
        guard !request.body.isEmpty else { return .error("Empty upload.", status: 400) }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudeman/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneAttachments(in: directory)

        let id = UUID().uuidString.lowercased()
        let url = directory.appendingPathComponent("\(id).\(ext)")
        do {
            try request.body.write(to: url, options: .atomic)
        } catch {
            return .error("Couldn't save the photo: \(error.localizedDescription)", status: 500)
        }
        attachments[id] = url.path
        return .json(AttachmentResponse(id: id), status: 201)
    }

    /// Deletes uploads older than a week.
    private func pruneAttachments(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func status() -> StatusResponse {
        let model = AppModel.shared
        let projects = model.projects.map { project in
            RemoteProject(
                id: project.id,
                name: project.name,
                path: project.displayPath,
                folderExists: project.folderExists,
                lastOpenedAt: project.lastOpenedAt,
                sessions: model.sessions(for: project.id).map(\.remote)
            )
        }
        return StatusResponse(server: serverInfo, projects: projects)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) -> T? {
        guard !request.body.isEmpty else { return nil }
        return try? RemoteAPI.makeDecoder().decode(type, from: request.body)
    }
}

private extension LaunchMode {
    init(_ remote: RemoteLaunchMode) {
        switch remote {
        case .new: self = .new
        case .continueLast: self = .continueLast
        }
    }
}

extension TerminalSession {
    var remote: RemoteSession {
        var pendingQuestion: String?
        var isWorking: Bool?
        if isRunning {
            let lines = screen().lines
            pendingQuestion = ScreenReader.prompt(in: lines)?.question
            isWorking = ScreenReader.activity(in: lines).isWorking
        }
        return RemoteSession(
            id: id, name: name, title: title, isRunning: isRunning, exitCode: exitCode, startedAt: startedAt,
            pendingQuestion: pendingQuestion, isWorking: isWorking
        )
    }
}

/// Addresses this Mac can be reached on, for display in Settings (LAN and Tailscale).
enum NetworkAddresses {
    static func current() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            result.append((String(cString: entry.pointee.ifa_name), address))
        }
        return result
    }
}
