import AppKit
import SwiftUI

struct ProjectEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: ProjectEditorRequest

    @State private var name = ""
    @State private var path = ""
    @State private var startSession = true

    private var isEditing: Bool {
        if case .edit = request { return true }
        return false
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !path.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Project" : "New Project")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $name)
                LabeledContent("Folder") {
                    HStack {
                        Text(path.isEmpty ? "None selected" : (path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(path.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if !isEditing {
                    Toggle("Start a Claude Code session now", isOn: $startSession)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: populate)
    }

    private func populate() {
        switch request {
        case .create(let folder):
            if let folder { use(folder) }
        case .edit(let project):
            name = project.name
            path = project.path
        }
    }

    private func use(_ folder: URL) {
        path = folder.path
        if name.isEmpty || !isEditing { name = folder.lastPathComponent }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder Claude Code should run in"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url {
            let previousDefault = (path as NSString).lastPathComponent
            path = url.path
            if name.isEmpty || name == previousDefault { name = url.lastPathComponent }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch request {
        case .create:
            let project = model.addProject(name: trimmed, path: path)
            if startSession { model.openSession(for: project, mode: UserDefaults.standard.defaultLaunchMode) }
        case .edit(var project):
            project.name = trimmed
            project.path = path
            model.updateProject(project)
        }
        dismiss()
    }
}
