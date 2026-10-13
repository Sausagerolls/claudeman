import AppKit
import SwiftUI

struct CloneRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var repository = ""
    @State private var parentDirectory = UserDefaults.standard.cloneDirectory
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var startSession = true

    @State private var cliReady: Bool?
    @State private var repositories: [GitHubRepository] = []
    @State private var listError: String?
    @State private var selection: GitHubRepository.ID?

    @State private var isCloning = false
    @State private var wasCancelled = false
    @State private var cloneProcess: Process?
    @State private var errorMessage: String?

    private var parsed: (source: String, name: String)? { GitHub.parse(repository) }

    private var destination: String {
        (parentDirectory as NSString).appendingPathComponent(folderName)
    }

    private var canClone: Bool {
        parsed != nil && !folderName.trimmed.isEmpty && !isCloning
    }

    private var filteredRepositories: [GitHubRepository] {
        let query = repository.trimmed.lowercased()
        guard !query.isEmpty, selection == nil else { return repositories }
        return repositories.filter {
            $0.nameWithOwner.lowercased().contains(query) || ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone from GitHub")
                .font(.title2.bold())

            TextField("Repository", text: $repository, prompt: Text("owner/repo or https://github.com/owner/repo"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: repository) { _, newValue in
                    if selection != nil, newValue != selection { selection = nil }
                    if !folderNameEdited { folderName = parsed?.name ?? "" }
                }

            repositoryList

            Form {
                LabeledContent("Clone into") {
                    HStack {
                        Text((parentDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseParentDirectory)
                    }
                }
                TextField("Folder name", text: Binding(
                    get: { folderName },
                    set: { folderName = $0; folderNameEdited = true }
                ))
                Toggle("Start a Claude Code session after cloning", isOn: $startSession)
            }
            .disabled(isCloning)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }

            HStack {
                if isCloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning \(parsed?.source ?? "")…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadRepositories() }
    }

    @ViewBuilder
    private var repositoryList: some View {
        switch cliReady {
        case nil:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking GitHub CLI…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case false:
            VStack(alignment: .leading, spacing: 6) {
                Text("Browse your repositories by installing the GitHub CLI and running `gh auth login`.")
                Text("You can still clone any public repository by URL or owner/repo.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case true:
            if let listError {
                Text(listError).foregroundStyle(.red).font(.callout)
            }
            List(filteredRepositories, selection: $selection) { repo in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.nameWithOwner)
                        if let description = repo.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .tag(repo.id)
            }
            .frame(height: 220)
            .overlay {
                if repositories.isEmpty && listError == nil {
                    ProgressView()
                }
            }
            .onChange(of: selection) { _, newValue in
                if let newValue { repository = newValue }
            }
            .disabled(isCloning)
        }
    }

    private func loadRepositories() async {
        let ready = await GitHub.isCLIReady()
        cliReady = ready
        guard ready else { return }
        do {
            repositories = try await GitHub.listRepositories()
        } catch {
            listError = error.localizedDescription
        }
    }

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the repository folder will be created"
        panel.directoryURL = URL(fileURLWithPath: parentDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            parentDirectory = url.path
        }
    }

    private func clone() {
        errorMessage = nil
        isCloning = true
        wasCancelled = false
        let name = folderName.trimmed

        Task {
            do {
                let path = try await GitHub.clone(
                    repository,
                    into: parentDirectory,
                    folderName: name,
                    useGitHubCLI: cliReady == true,
                    onStart: { process in Task { @MainActor in cloneProcess = process } }
                )
                let project = model.addProject(name: name, path: path)
                if startSession {
                    model.openSession(for: project, mode: UserDefaults.standard.defaultLaunchMode)
                }
                dismiss()
            } catch {
                if wasCancelled {
                    // Remove the partial checkout left by an interrupted clone.
                    try? FileManager.default.removeItem(atPath: (parentDirectory as NSString).appendingPathComponent(name))
                    dismiss()
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isCloning = false
            cloneProcess = nil
        }
    }

    private func cancel() {
        if isCloning, let cloneProcess {
            wasCancelled = true
            cloneProcess.terminate()
        } else {
            dismiss()
        }
    }
}
