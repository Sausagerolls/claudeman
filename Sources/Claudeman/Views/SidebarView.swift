import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var projectPendingRemoval: Project?

    var body: some View {
        List(selection: $model.selectedProjectID) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project, runningCount: model.runningSessionCount(for: project.id))
                        .tag(project.id)
                        .contextMenu { contextMenu(for: project) }
                }
                .onMove(perform: model.moveProjects)
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            model.editorRequest = .create(folder: folder)
            return true
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        model.editorRequest = .create(folder: nil)
                    } label: {
                        Label("New Project from Folder…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        model.isClonePresented = true
                    } label: {
                        Label("Clone from GitHub…", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                } primaryAction: {
                    model.editorRequest = .create(folder: nil)
                }
                .help("New Project")
            }
        }
        .confirmationDialog(
            "Remove “\(projectPendingRemoval?.name ?? "")”?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            presenting: projectPendingRemoval
        ) { project in
            Button("Remove", role: .destructive) { model.removeProject(id: project.id) }
        } message: { _ in
            Text("The project is removed from Claudeman and its sessions are ended. The folder on disk is not touched.")
        }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        ForEach(LaunchMode.allCases) { mode in
            Button(mode.title) { model.openSession(for: project, mode: mode) }
                .disabled(!project.folderExists)
        }
        Divider()
        Button("Reveal in Finder") { model.revealInFinder(project) }
        Button("Open in Terminal") { model.openInTerminal(project) }
        Divider()
        Button("Edit Project…") { model.editorRequest = .edit(project) }
        Button("Remove Project…", role: .destructive) { projectPendingRemoval = project }
    }
}

private struct ProjectRow: View {
    @AppStorage(SettingsKey.showProjectPaths) private var showPath = true
    let project: Project
    let runningCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                if showPath || !project.folderExists {
                    Text(project.displayPath)
                        .font(.caption)
                        .foregroundStyle(project.folderExists ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if runningCount > 0 {
                Text("\(runningCount)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.green.opacity(0.25)))
                    .help("\(runningCount) running session(s)")
            }
        }
        .padding(.vertical, 2)
    }
}
