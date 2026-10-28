import ClaudemanKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.scenePhase) private var scenePhase
    let mac: PairedMac

    @State private var status: StatusResponse?
    @State private var connectionError: String?
    @State private var isUnauthorized = false
    @State private var lastUpdated: Date?
    @State private var busy: Set<UUID> = []
    @State private var actionError: String?
    @State private var sessionToStop: RemoteSession?
    @State private var confirmRemove = false

    private static let refreshInterval: Duration = .seconds(3)

    private var projects: [RemoteProject] {
        (status?.projects ?? []).sorted { lhs, rhs in
            if (lhs.runningCount > 0) != (rhs.runningCount > 0) { return lhs.runningCount > 0 }
            return (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
        }
    }

    var body: some View {
        List {
            if isUnauthorized {
                Section {
                    Label("This device was removed on the Mac, or the Mac was reset.", systemImage: "lock.slash")
                    Button("Forget This Mac", role: .destructive) { store.remove(mac) }
                } footer: {
                    Text("Forget it, then pair again from the Macs list.")
                }
            } else if let connectionError {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Can't reach \(mac.name)")
                            Text(connectionError).font(.caption).foregroundStyle(.secondary)
                            if let lastUpdated {
                                Text("Last updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    }
                }
            }

            ForEach(projects) { project in
                Section {
                    if project.sessions.isEmpty {
                        Text("No sessions").foregroundStyle(.secondary)
                    }
                    ForEach(project.sessions) { session in
                        SessionRow(session: session, isBusy: busy.contains(session.id)) { action in
                            handle(action, session: session)
                        }
                    }
                } header: {
                    ProjectHeader(project: project, isBusy: busy.contains(project.id)) { mode in
                        perform(project.id) { try await $0.startSession(projectID: project.id, mode: mode) }
                    }
                } footer: {
                    if !project.folderExists {
                        Text("Folder missing on the Mac: \(project.path)")
                    }
                }
            }
        }
        .overlay {
            if status == nil && connectionError == nil && !isUnauthorized {
                ProgressView("Connecting to \(mac.name)…")
            } else if status?.projects.isEmpty == true {
                ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Add a project in Claudeman on your Mac."))
            }
        }
        .navigationTitle(mac.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Text(mac.address)
                    if let version = status?.server.appVersion { Text("Claudeman \(version)") }
                    Button("Forget This Mac", systemImage: "trash", role: .destructive) { confirmRemove = true }
                } label: {
                    Label("Mac", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable { await refresh() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .confirmationDialog(
            "Stop \(sessionToStop?.name ?? "session")?",
            isPresented: Binding(get: { sessionToStop != nil }, set: { if !$0 { sessionToStop = nil } }),
            titleVisibility: .visible,
            presenting: sessionToStop
        ) { session in
            Button("Stop Session", role: .destructive) {
                perform(session.id) { try await $0.stop(sessionID: session.id) }
            }
        } message: { _ in
            Text("Claude Code will be ended on the Mac. You can continue the conversation later.")
        }
        .confirmationDialog("Forget \(mac.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { store.remove(mac) }
        } message: {
            Text("You'll need to pair again to control this Mac.")
        }
        .alert("Couldn't Complete Action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func handle(_ action: SessionAction, session: RemoteSession) {
        switch action {
        case .restart(let mode):
            perform(session.id) { try await $0.restart(sessionID: session.id, mode: mode) }
        case .stop:
            sessionToStop = session
        case .close:
            perform(session.id) { try await $0.close(sessionID: session.id) }
        }
    }

    private func refresh() async {
        guard let client = store.client(for: mac) else { return }
        do {
            status = try await client.status()
            lastUpdated = Date()
            connectionError = nil
            isUnauthorized = false
        } catch RemoteError.unauthorized {
            isUnauthorized = true
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func perform(_ id: UUID, _ operation: @escaping (RemoteClient) async throws -> Void) {
        guard let client = store.client(for: mac) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                try await operation(client)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await refresh()
            } catch {
                actionError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct ProjectHeader: View {
    let project: RemoteProject
    let isBusy: Bool
    let onStart: (RemoteLaunchMode) -> Void

    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            if isBusy {
                ProgressView()
            } else {
                Menu {
                    ForEach(RemoteLaunchMode.allCases, id: \.self) { mode in
                        Button(mode.title, systemImage: mode.systemImage) { onStart(mode) }
                    }
                } label: {
                    Label("Start", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .disabled(!project.folderExists)
                .textCase(nil)
            }
        }
    }
}

enum SessionAction {
    case restart(RemoteLaunchMode)
    case stop
    case close
}

private struct SessionRow: View {
    let session: RemoteSession
    let isBusy: Bool
    let onAction: (SessionAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.body.weight(.medium))
                if !session.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(session.title).font(.subheadline).lineLimit(2)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView()
            } else {
                Menu {
                    Section("Restart") {
                        ForEach(RemoteLaunchMode.allCases, id: \.self) { mode in
                            Button(mode.title, systemImage: mode.systemImage) { onAction(.restart(mode)) }
                        }
                    }
                    if session.isRunning {
                        Button("Stop", systemImage: "stop.circle", role: .destructive) { onAction(.stop) }
                    } else {
                        Button("Close Tab", systemImage: "xmark", role: .destructive) { onAction(.close) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            if !session.isRunning {
                Button { onAction(.restart(.continueLast)) } label: {
                    Label("Continue", systemImage: "arrow.uturn.forward")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if session.isRunning {
                Button { onAction(.stop) } label: { Label("Stop", systemImage: "stop.circle") }
                    .tint(.red)
            } else {
                Button(role: .destructive) { onAction(.close) } label: { Label("Close", systemImage: "xmark") }
            }
        }
    }

    private var subtitle: String {
        if session.isRunning {
            return "Running · started \(session.startedAt.formatted(.relative(presentation: .named)))"
        }
        switch session.exitCode {
        case 129, 143: return "Stopped"   // SIGHUP / SIGTERM
        case let code? where code != 0: return "Ended · exit code \(code)"
        default: return "Ended"
        }
    }
}

extension RemoteLaunchMode {
    var systemImage: String {
        switch self {
        case .new: "plus"
        case .continueLast: "arrow.uturn.forward"
        }
    }
}
