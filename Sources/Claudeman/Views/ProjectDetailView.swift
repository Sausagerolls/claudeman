import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    let project: Project

    var body: some View {
        let sessions = model.sessions(for: project.id)
        let selected = model.selectedSession(for: project.id)

        VStack(spacing: 0) {
            if !project.folderExists {
                MissingFolderBanner(project: project)
            }
            if !sessions.isEmpty {
                SessionTabBar(project: project, sessions: sessions, selectedID: selected?.id)
                Divider()
            }
            if let selected {
                SessionView(session: selected)
                    .id(selected.id)
            } else {
                emptyState
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(project.displayPath)
        .toolbar {
            ToolbarItemGroup {
                Button { model.revealInFinder(project) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
                NewSessionMenu(project: project)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "terminal")
        } description: {
            Text("Start Claude Code in \(project.displayPath)")
        } actions: {
            HStack {
                ForEach(LaunchMode.allCases) { mode in
                    Button {
                        model.openSession(for: project, mode: mode)
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                    .controlSize(.large)
                    .buttonStyle(mode == .new ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
                }
            }
            .disabled(!project.folderExists)
        }
    }
}

struct NewSessionMenu: View {
    @EnvironmentObject private var model: AppModel
    let project: Project

    var body: some View {
        Menu {
            ForEach(LaunchMode.allCases) { mode in
                Button { model.openSession(for: project, mode: mode) } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }
        } label: {
            Label("New Session", systemImage: "plus")
        } primaryAction: {
            model.openSession(for: project, mode: .new)
        }
        .disabled(!project.folderExists)
        .help("New Claude Code session")
    }
}

private struct MissingFolderBanner: View {
    @EnvironmentObject private var model: AppModel
    let project: Project

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Folder not found: \(project.displayPath)")
            Spacer()
            Button("Change Folder…") { model.editorRequest = .edit(project) }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

/// Type-erases the two button styles used by the empty state.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let makeBody: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBody(configuration)
    }
}
