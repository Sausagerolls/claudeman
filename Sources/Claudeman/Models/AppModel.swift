import AppKit
import SwiftUI

/// What the project editor sheet is doing.
enum ProjectEditorRequest: Identifiable {
    case create(folder: URL?)
    case edit(Project)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let project): project.id.uuidString
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var projects: [Project] = [] {
        didSet { save() }
    }
    @Published var selectedProjectID: UUID?
    @Published private(set) var sessions: [TerminalSession] = []
    /// Selected session tab, per project.
    @Published var selectedSessionIDs: [UUID: UUID] = [:]
    @Published var editorRequest: ProjectEditorRequest?
    @Published var isClonePresented = false

    private let storeURL: URL
    private var sessionCounters: [UUID: Int] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudeman", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("projects.json")
        load()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
    }

    // MARK: Preferences

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Pushes the current settings to the app appearance and every open terminal.
    func applyPreferences() {
        let appearance = UserDefaults.standard.appearance.nsAppearance
        if NSApp.appearance != appearance { NSApp.appearance = appearance }
        let preferences = TerminalPreferences.current(isDark: isDark)
        sessions.forEach { $0.apply(preferences) }
    }

    // MARK: Projects

    var selectedProject: Project? {
        selectedProjectID.flatMap(project(id:))
    }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func addProject(name: String, path: String) -> Project {
        let project = Project(name: name, path: path)
        projects.append(project)
        selectedProjectID = project.id
        return project
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    func removeProject(id: UUID) {
        closeAllSessions(projectID: id)
        projects.removeAll { $0.id == id }
        selectedSessionIDs[id] = nil
        sessionCounters[id] = nil
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
    }

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    func openInTerminal(_ project: Project) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([project.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Sessions

    func sessions(for projectID: UUID) -> [TerminalSession] {
        sessions.filter { $0.projectID == projectID }
    }

    func runningSessionCount(for projectID: UUID) -> Int {
        sessions.filter { $0.projectID == projectID && $0.isRunning }.count
    }

    var runningSessionCount: Int {
        sessions.filter(\.isRunning).count
    }

    func selectedSession(for projectID: UUID) -> TerminalSession? {
        let projectSessions = sessions(for: projectID)
        if let id = selectedSessionIDs[projectID], let session = projectSessions.first(where: { $0.id == id }) {
            return session
        }
        return projectSessions.last
    }

    @discardableResult
    func openSession(for project: Project, mode: LaunchMode) -> TerminalSession? {
        guard project.folderExists else { return nil }
        let session = makeSession(for: project, mode: mode)
        sessions.append(session)
        select(session)
        return session
    }

    /// Replaces a finished session with a fresh one in the same tab position.
    func restart(_ old: TerminalSession, mode: LaunchMode) {
        guard let project = project(id: old.projectID), project.folderExists,
              let index = sessions.firstIndex(where: { $0.id == old.id }) else { return }
        old.terminate()
        let session = makeSession(for: project, mode: mode)
        sessions[index] = session
        select(session)
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionIDs[session.projectID] == session.id {
            selectedSessionIDs[session.projectID] = sessions(for: session.projectID).last?.id
        }
    }

    func closeAllSessions(projectID: UUID) {
        sessions(for: projectID).forEach(close)
    }

    func select(_ session: TerminalSession) {
        selectedProjectID = session.projectID
        selectedSessionIDs[session.projectID] = session.id
    }

    private func makeSession(for project: Project, mode: LaunchMode) -> TerminalSession {
        let number = (sessionCounters[project.id] ?? 0) + 1
        sessionCounters[project.id] = number

        var touched = project
        touched.lastOpenedAt = Date()
        updateProject(touched)

        let session = TerminalSession(
            project: project,
            name: "Session \(number)",
            mode: mode,
            preferences: TerminalPreferences.current(isDark: isDark)
        )
        session.onStateChange = { [weak self] in self?.objectWillChange.send() }
        return session
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = (try? decoder.decode([Project].self, from: data)) ?? []
        selectedProjectID = projects.first?.id
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
