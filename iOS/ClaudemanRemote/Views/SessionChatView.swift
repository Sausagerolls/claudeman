import ClaudemanKit
import PhotosUI
import SwiftUI

/// Chat with one Claude Code session: the conversation, a live view of the terminal's
/// last lines (for prompts and progress), keys for answering prompts, and a composer
/// with photo attachments.
struct SessionChatView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.scenePhase) private var scenePhase
    let mac: PairedMac

    @State private var sessionID: UUID
    @State private var session: RemoteSession?
    @State private var messages: [ChatMessage] = []
    @State private var cursor: Int?
    @State private var hasTranscript = true
    @State private var screen: ScreenSnapshot?
    @State private var connectionError: String?
    @State private var actionError: String?
    @State private var showFullScreen = false
    @AppStorage("showTerminalPanel") private var showTerminal = true

    @State private var draft = ""
    @State private var photos: [PickedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var isSending = false
    @FocusState private var composerFocused: Bool

    private static let refreshInterval: Duration = .milliseconds(1500)

    init(mac: PairedMac, session: RemoteSession) {
        self.mac = mac
        _sessionID = State(initialValue: session.id)
        _session = State(initialValue: session)
    }

    private var client: RemoteClient? { store.client(for: mac) }
    private var isRunning: Bool { session?.isRunning ?? false }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            if let connectionError {
                Label(connectionError, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
            if isRunning {
                if showTerminal, let screen { TerminalPanel(screen: screen) { showFullScreen = true } }
                KeyBar { press($0) }
                composer
            } else if session != nil {
                endedBar
            }
        }
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Show Terminal", systemImage: "terminal", isOn: $showTerminal)
                    Button("Full Terminal Screen", systemImage: "arrow.up.left.and.arrow.down.right") { showFullScreen = true }
                        .disabled(screen == nil)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showFullScreen) {
            if let screen { FullScreenTerminal(screen: screen) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in add(image) }
                .ignoresSafeArea()
        }
        .onChange(of: pickerItems) { _, items in
            Task { await loadPicked(items) }
        }
        .task(id: "\(sessionID)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .alert("Couldn't Send", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(hasTranscript ? "No messages yet." : "Waiting for Claude Code to start…")
                                .foregroundStyle(.secondary)
                            Text("Send a message below. Use the terminal panel and keys to answer prompts.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(photos) { photo in
                            Image(uiImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        photos.removeAll { $0.id == photo.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .padding(3)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Take Photo", systemImage: "camera") { showCamera = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Attach")

                TextField("Message Claude", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await sendMessage() }
                } label: {
                    if isSending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                }
                .disabled(isSending || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty))
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var endedBar: some View {
        VStack(spacing: 10) {
            Text(session?.exitCode == 143 || session?.exitCode == 129 ? "This session was stopped." : "This session has ended.")
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await restart(.continueLast) }
                } label: {
                    Label("Continue", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await restart(.new) }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    // MARK: Actions

    private func refresh() async {
        guard let client else { return }
        do {
            let response = try await client.chat(sessionID: sessionID, after: cursor)
            if response.reset {
                messages = response.messages
            } else if !response.messages.isEmpty {
                messages += response.messages
            }
            cursor = response.cursor
            session = response.session
            hasTranscript = response.hasTranscript
            screen = response.screen
            connectionError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch RemoteError.server(_, status: 404) {
            connectionError = "This session was closed on the Mac."
            session?.isRunning = false
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func sendMessage() async {
        guard let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = photos
        isSending = true
        defer { isSending = false }
        do {
            var ids: [String] = []
            for photo in attached {
                ids.append(try await client.uploadImage(sessionID: sessionID, jpeg: photo.jpeg))
            }
            try await client.input(sessionID: sessionID, InputRequest(text: text, attachments: ids, submit: true))
            draft = ""
            photos.removeAll { photo in attached.contains { $0.id == photo.id } }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func press(_ key: TerminalKey) {
        guard let client else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await client.input(sessionID: sessionID, InputRequest(keys: [key]))
                try? await Task.sleep(for: .milliseconds(250))
                await refresh()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func restart(_ mode: RemoteLaunchMode) async {
        guard let client else { return }
        do {
            let response = try await client.restart(sessionID: sessionID, mode: mode)
            // The Mac replaces the session with a new one; follow it.
            sessionID = response.session.id
            session = response.session
            messages = []
            cursor = nil
            screen = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                add(image)
            }
        }
        pickerItems = []
    }

    private func add(_ image: UIImage) {
        guard let photo = PickedPhoto(image: image) else { return }
        photos.append(photo)
    }
}

// MARK: - Messages

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if message.imageCount > 0 {
                        Label(message.imageCount == 1 ? "Photo" : "\(message.imageCount) photos", systemImage: "photo")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            }

        case .assistant:
            Text(markdown(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(for: message.toolName ?? ""))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(message.toolName ?? "Tool")
                    .fontWeight(.semibold)
                if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .font(.caption.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func icon(for tool: String) -> String {
        switch tool {
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Terminal

/// The last few non-blank lines of the Mac's terminal, so prompts and progress are visible.
private struct TerminalPanel: View {
    let screen: ScreenSnapshot
    let onExpand: () -> Void

    private var tail: [String] {
        var lines = screen.lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(8))
    }

    var body: some View {
        Button(action: onExpand) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(white: 0.88))
                .padding(8)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Terminal. Double-tap to show the full screen.")
    }
}

private struct FullScreenTerminal: View {
    @Environment(\.dismiss) private var dismiss
    let screen: ScreenSnapshot

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(screen.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.9))
                .textSelection(.enabled)
                .padding()
            }
            .background(Color(white: 0.11))
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Keys for answering Claude Code's prompts and menus.
private struct KeyBar: View {
    let onPress: (TerminalKey) -> Void

    private let keys: [(TerminalKey, String)] = [
        (.digit1, "1"), (.digit2, "2"), (.digit3, "3"),
        (.enter, "⏎ Enter"), (.escape, "Esc"), (.up, "↑"), (.down, "↓"),
        (.shiftTab, "⇧⇥ Mode"), (.tab, "⇥"), (.ctrlC, "⌃C"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.0) { key, label in
                    Button(label) { onPress(key) }
                        .font(.callout.monospaced())
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

// MARK: - Photos

struct PickedPhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let jpeg: Data

    /// Downscales to at most 2048 px on the long side, which is plenty for Claude, and encodes JPEG.
    init?(image: UIImage) {
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        self.jpeg = jpeg
        thumbnail = resized.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? resized
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
