import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let project = model.selectedProject {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label("No Project Selected", systemImage: "folder")
                } description: {
                    Text("Create a project to start a Claude Code session in its folder.")
                } actions: {
                    HStack {
                        Button("New Project…") { model.editorRequest = .create(folder: nil) }
                        Button("Clone from GitHub…") { model.isClonePresented = true }
                    }
                }
            }
        }
        .sheet(item: $model.editorRequest) { request in
            ProjectEditorView(request: request)
        }
        .sheet(isPresented: $model.isClonePresented) {
            CloneRepositoryView()
        }
        // "Match Appearance" terminal themes follow the window's light/dark state.
        .onChange(of: colorScheme) { model.applyPreferences() }
    }
}
