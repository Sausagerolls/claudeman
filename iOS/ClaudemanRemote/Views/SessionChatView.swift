import ClaudemanKit
import PhotosUI
import SwiftUI

/// Chat with one Claude Code session.
///
/// Claude's questions and permission requests are recognised on the Mac and shown here as
/// native cards, so you never need to see the terminal.
struct SessionChatView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.scenePhase) private var scenePhase
    let mac: PairedMac

    @State private var sessionID: UUID
    @State private var session: RemoteSession?
    @State private var messages: [ChatMessage] = []
    /// False until the first transcript load; the conversation stays hidden until then so it
    /// appears already scrolled to the latest message instead of visibly scrolling there.
    @State private var hasLoaded = false
    @AppStorage(SettingsKey.showToolSteps) private var showToolSteps = true
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = false
    @State private var isRevealed = false
    /// True while the latest message is on screen; new messages only auto-scroll then.
    /// Whether the end-of-conversation marker is on screen. Exact, but a big jump can remove the
    /// marker without reporting it left, so it's paired with a coarse distance check.
    @State private var endMarkerVisible = true
    /// More than a screen away from the end, from scroll geometry (heights are estimates, which
    /// is fine at this scale).
    @State private var farFromEnd = false
    private var isNearBottom: Bool { endMarkerVisible && !farFromEnd }
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var cursor: Int?
    @State private var hasTranscript = true
    @State private var screen: ScreenSnapshot?
    @State private var prompt: PendingPrompt?
    @State private var activity: SessionActivity?
    @State private var connectionError: String?
    @State private var actionError: String?
    @State private var showTerminal = false

    /// Messages sent from this device that haven't appeared in the transcript yet.
    @State private var outbox: [OutgoingMessage] = []
    @State private var draft = ""
    @State private var photos: [PickedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @FocusState private var composerFocused: Bool

    init(mac: PairedMac, session: RemoteSession) {
        self.mac = mac
        _sessionID = State(initialValue: session.id)
        _session = State(initialValue: session)
    }

    private var client: RemoteClient? { store.client(for: mac) }
    private var isRunning: Bool { session?.isRunning ?? false }
    private var isWorking: Bool { activity?.isWorking ?? false }

    /// Poll faster while something is happening.
    private var refreshInterval: Duration {
        AppSettings.interval(isWorking || prompt != nil || !outbox.isEmpty ? .milliseconds(900) : .milliseconds(2000))
    }

    var body: some View {
        conversation
            .environment(\.chatImageLoader, ChatImageLoader(client: client, sessionID: sessionID))
            .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .onChange(of: keepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(session?.name ?? "Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleView }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("View Terminal", systemImage: "terminal") { showTerminal = true }
                            .disabled(screen == nil)
                        if isRunning {
                            Button("Interrupt Claude", systemImage: "stop.circle") { press(.escape) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showTerminal) {
                if let screen { TerminalSheet(screen: screen) }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 5, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in add(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadPicked(items) }
            }
            .onChange(of: prompt?.id) { old, new in
                if new != nil, old == nil {
                    composerFocused = false
                    Haptics.notify(.warning)
                }
            }
            .task(id: "\(sessionID)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: refreshInterval)
                }
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
    }

    private var titleView: some View {
        VStack(spacing: 0) {
            Text(session?.name ?? "Session").font(.headline)
            Group {
                if let connectionError {
                    Text(connectionError).foregroundStyle(.orange)
                } else if prompt != nil {
                    Text("Waiting for your answer").foregroundStyle(.orange)
                } else if isWorking {
                    Text(activity?.label ?? "Working…")
                } else if !isRunning, session != nil {
                    Text("Ended")
                } else if let title = session?.title, !title.isEmpty {
                    Text(title)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && outbox.isEmpty {
                        emptyState
                    }
                    ForEach(ChatItem.group(showToolSteps ? messages : messages.filter { $0.kind != .tool })) { item in
                        switch item {
                        case .message(let message): MessageView(message: message)
                        case .tools(let tools): ToolGroupView(tools: tools)
                        }
                    }
                    ForEach(outbox) { message in
                        UserBubble(text: message.text, thumbnails: message.thumbnails, images: [],
                                   imageCount: message.thumbnails.count, isPending: true)
                    }
                    if isWorking && prompt == nil {
                        WorkingIndicator(label: activity?.label)
                            .transition(.opacity)
                    }
                    // End-of-conversation marker. Whether it's on screen decides auto-scrolling and
                    // the Latest button (content heights are only estimates in a lazy stack).
                    Color.clear.frame(height: 1)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            endMarkerVisible = visible
                        }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.2), value: messages.count)
                .animation(.easeOut(duration: 0.2), value: isWorking)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                return geometry.contentSize.height - visibleBottom > geometry.containerSize.height
            } action: { _, far in
                farFromEnd = far
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .opacity(isRevealed ? 1 : 0)
            .overlay {
                if !isRevealed { ProgressView() }
            }
            .overlay(alignment: .bottom) {
                if isRevealed && !isNearBottom {
                    Button {
                        scrollToBottom()
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel("Jump to latest message")
                }
            }
            .animation(.easeOut(duration: 0.2), value: isNearBottom)
            .onChange(of: hasLoaded) { _, loaded in
                guard loaded else { return }
                // Jump (no animation) while hidden, then show it already at the latest message.
                Task {
                    await settleAtBottom()
                    isRevealed = true
                }
            }
            .onChange(of: messages.last?.id) { if isRevealed && isNearBottom { scrollToBottom() } }
            .onChange(of: outbox.count) { if isRevealed { scrollToBottom() } }   // you just sent something
            .onChange(of: isWorking) { if isRevealed && isNearBottom { scrollToBottom() } }
            .onChange(of: prompt?.id) { if isRevealed && isNearBottom { scrollToBottom() } }
            #if DEBUG
            .task(id: isRevealed) {
                // Development aid: `-scrollTest` scrolls to the top, then runs the Latest button's jump.
                guard isRevealed, ProcessInfo.processInfo.arguments.contains("-scrollTest") else { return }
                try? await Task.sleep(for: .seconds(2))
                scrollPosition.scrollTo(edge: .top)
                try? await Task.sleep(for: .seconds(3))
                scrollToBottom()
            }
            #endif
    }

    /// Scrolls to the end by edge rather than by a view id: in a lazy stack the end marker
    /// may not exist yet when you're far up, and scrolling to a missing id does nothing.
    private func scrollToBottom() {
        withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
        // A long jump through the lazy list can land short (row heights are estimated
        // until laid out), so finish the trip once the animation is done.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await settleAtBottom()
        }
    }

    /// Repeats the jump until the end of the conversation is really in view.
    private func settleAtBottom() async {
        for _ in 0..<15 {
            scrollPosition.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(40))
            if isNearBottom { break }
        }
        scrollPosition.scrollTo(edge: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(hasTranscript || !isRunning ? "Start the conversation" : "Starting Claude Code…")
                .font(.headline)
            Text("Send a message or a photo. If Claude asks a question, it appears here for you to answer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if !isRunning, session != nil {
            endedBar
        } else if let prompt {
            PromptCard(prompt: prompt) { option, text in
                await answer(option, text: text, in: prompt)
            } onDismiss: {
                press(.escape)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            Image(uiImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        withAnimation { photos.removeAll { $0.id == photo.id } }
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
                    .padding(.horizontal)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Take Photo", systemImage: "camera") { showCamera = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .accessibilityLabel("Attach photo")

                HStack(alignment: .bottom) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.vertical, 8)
                        .padding(.leading, 14)
                    sendOrStopButton
                        .padding(3)
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isWorking && !canSend {
            Button { press(.escape) } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
            }
            .accessibilityLabel("Stop Claude")
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canSend ? Color.accentColor : Color(.systemGray3), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var endedBar: some View {
        VStack(spacing: 12) {
            Text(session?.exitCode == 143 || session?.exitCode == 129 ? "This session was stopped." : "This session has ended.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await restart(.continueLast) }
                } label: {
                    Label("Continue", systemImage: "arrow.uturn.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await restart(.new) }
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
    }

    // MARK: Actions

    private func refresh() async {
        guard let client else { return }
        do {
            let response = try await client.chat(sessionID: sessionID, after: cursor)
            if !hasLoaded {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { messages = response.messages }
                hasLoaded = true
            } else if response.reset {
                messages = response.messages
            } else if !response.messages.isEmpty {
                messages += response.messages
            }
            // Drop optimistic messages once the transcript has caught up with them.
            let newUserMessages = response.messages.filter { $0.kind == .user }.count
            if newUserMessages > 0 { outbox.removeFirst(min(newUserMessages, outbox.count)) }

            cursor = response.cursor
            session = response.session
            hasTranscript = response.hasTranscript
            screen = response.screen
            withAnimation(.spring(duration: 0.3)) { prompt = response.prompt }
            activity = response.activity
            connectionError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch RemoteError.server(_, status: 404) {
            connectionError = "Closed on the Mac"
            session?.isRunning = false
        } catch {
            connectionError = "Reconnecting…"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = photos
        guard let client, !text.isEmpty || !attached.isEmpty else { return }

        let outgoing = OutgoingMessage(text: text, thumbnails: attached.map(\.thumbnail))
        withAnimation { outbox.append(outgoing) }
        draft = ""
        photos = []
        Haptics.tap(.light)

        Task {
            do {
                var ids: [String] = []
                for photo in attached {
                    ids.append(try await client.uploadImage(sessionID: sessionID, jpeg: photo.jpeg))
                }
                try await client.input(sessionID: sessionID, InputRequest(text: text, attachments: ids, submit: true))
                await refresh()
            } catch {
                // Put the message back so nothing is lost.
                outbox.removeAll { $0.id == outgoing.id }
                draft = text
                photos = attached
                actionError = error.localizedDescription
            }
        }
    }

    private func answer(_ option: PendingPrompt.Option, text: String?, in prompt: PendingPrompt) async {
        guard let client else { return }
        Haptics.tap(.medium)
        do {
            try await client.answer(sessionID: sessionID, AnswerRequest(promptID: prompt.id, optionIndex: option.index, text: text))
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        } catch RemoteError.server(_, status: 409) {
            await refresh()   // the question moved on; show the current one
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func press(_ key: TerminalKey) {
        guard let client else { return }
        Haptics.tap(.light)
        Task {
            try? await client.input(sessionID: sessionID, InputRequest(keys: [key]))
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
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
            hasLoaded = false
            isRevealed = false
            outbox = []
            cursor = nil
            screen = nil
            prompt = nil
            activity = nil
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
        withAnimation { photos.append(photo) }
    }
}

private struct OutgoingMessage: Identifiable {
    let id = UUID()
    let text: String
    let thumbnails: [UIImage]
}

// MARK: - Prompt card

/// A question, menu or permission request, answered with a tap.
private struct PromptCard: View {
    let prompt: PendingPrompt
    let onAnswer: (PendingPrompt.Option, String?) async -> Void
    let onDismiss: () -> Void

    @State private var busy = false
    @State private var customText = ""
    @State private var isTypingCustom = false
    @FocusState private var customFocused: Bool

    private var mainOptions: [PendingPrompt.Option] { prompt.options.filter { !$0.isSecondary && !$0.acceptsText } }
    private var textOption: PendingPrompt.Option? { prompt.options.first(where: \.acceptsText) }
    private var secondaryOptions: [PendingPrompt.Option] { prompt.options.filter(\.isSecondary) }
    private var isPermission: Bool { prompt.code != nil || prompt.question.localizedCaseInsensitiveContains("proceed") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let code = prompt.code {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.callout.monospaced())
                        .padding(10)
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            }

            // Short lists sit naturally; long ones scroll within the card.
            ViewThatFits(in: .vertical) {
                optionList
                ScrollView { optionList }
                    .frame(maxHeight: 360)
            }

            if !secondaryOptions.isEmpty {
                HStack {
                    ForEach(secondaryOptions, id: \.index) { option in
                        Button(option.label) { choose(option) }
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.accentColor.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .onChange(of: prompt.id) {
            busy = false
            isTypingCustom = false
            customText = ""
        }
    }

    private var optionList: some View {
        // In checkbox forms the unnumbered "Submit" item goes last, after "write your own".
        let choices = mainOptions.filter { !prompt.isMultiSelect || $0.isChecked != nil }
        let actions = mainOptions.filter { prompt.isMultiSelect && $0.isChecked == nil }
        return VStack(spacing: 8) {
            ForEach(choices, id: \.index) { option in
                optionButton(option)
            }
            if let textOption {
                customAnswer(textOption)
            }
            ForEach(actions, id: \.index) { option in
                optionButton(option)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(isPermission ? (prompt.title ?? "Permission needed") : "Claude is asking",
                      systemImage: isPermission ? "lock.shield" : "questionmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Dismiss (Esc)")
            }

            if !prompt.steps.isEmpty {
                HStack(spacing: 6) {
                    ForEach(prompt.steps, id: \.label) { step in
                        Label(step.label, systemImage: step.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(step.isDone ? Color.accentColor : .secondary)
                    }
                }
            }

            Text(prompt.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = prompt.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isPermission, let title = prompt.title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func optionButton(_ option: PendingPrompt.Option) -> some View {
        Button { choose(option) } label: {
            HStack(alignment: .top, spacing: 12) {
                if let checked = option.isChecked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                // "Yes, and switch to auto mode · auto mode handles…" → label plus explanation.
                let parts = option.label.components(separatedBy: " · ")
                let explanation = ([parts.dropFirst().joined(separator: " · ")] + [option.detail ?? ""])
                    .filter { !$0.isEmpty }.joined(separator: " ")
                VStack(alignment: .leading, spacing: 2) {
                    Text(parts[0])
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if !explanation.isEmpty {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(for: option), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func background(for option: PendingPrompt.Option) -> Color {
        // The unnumbered "Submit" item of a checkbox form, and the first answer of a plain
        // question, get the accent so the likely choice stands out.
        if prompt.isMultiSelect && option.isChecked == nil { return Color.accentColor.opacity(0.25) }
        if !prompt.isMultiSelect && option.index == mainOptions.first?.index { return Color.accentColor.opacity(0.18) }
        return Color(.secondarySystemFill)
    }

    @ViewBuilder
    private func customAnswer(_ option: PendingPrompt.Option) -> some View {
        if isTypingCustom {
            HStack(spacing: 8) {
                TextField("Your answer", text: $customText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($customFocused)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    busy = true
                    Task { await onAnswer(option, text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onAppear { customFocused = true }
        } else {
            Button {
                withAnimation { isTypingCustom = true }
            } label: {
                Label("Write your own answer…", systemImage: "square.and.pencil")
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func choose(_ option: PendingPrompt.Option) {
        // Checkbox toggles keep the card up; everything else moves the conversation on.
        if option.isChecked == nil { busy = true }
        Task {
            await onAnswer(option, nil)
            busy = false
        }
    }
}

// MARK: - Messages

/// Consecutive tool calls are collapsed into one row to keep the conversation readable.
private enum ChatItem: Identifiable {
    case message(ChatMessage)
    case tools([ChatMessage])

    var id: String {
        switch self {
        case .message(let message): message.id
        case .tools(let tools): "tools-\(tools[0].id)"
        }
    }

    static func group(_ messages: [ChatMessage]) -> [ChatItem] {
        var items: [ChatItem] = []
        for message in messages {
            if message.kind == .tool, case .tools(let tools)? = items.last {
                items[items.count - 1] = .tools(tools + [message])
            } else if message.kind == .tool {
                items.append(.tools([message]))
            } else {
                items.append(.message(message))
            }
        }
        return items
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.kind {
        case .user:
            UserBubble(text: message.text, thumbnails: [], images: message.images ?? [],
                       imageCount: message.imageCount, isPending: false)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty { AssistantText(text: message.text) }
                if let images = message.images, !images.isEmpty { ChatImageStrip(images: images) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolGroupView(tools: [message])
        }
    }
}

private struct UserBubble: View {
    let text: String
    let thumbnails: [UIImage]
    /// Photos from the transcript, loaded from the Mac.
    let images: [ChatImage]
    let imageCount: Int
    let isPending: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                if !thumbnails.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !images.isEmpty {
                    ChatImageStrip(images: images)
                }
                // Older Macs don't send image ids; fall back to a badge inside the bubble.
                let badge = thumbnails.isEmpty && images.isEmpty && imageCount > 0
                if !text.isEmpty || badge {
                    VStack(alignment: .trailing, spacing: 4) {
                        if badge {
                            Label(imageCount == 1 ? "Photo" : "\(imageCount) photos", systemImage: "photo")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if !text.isEmpty {
                            Text(text)
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20))
                }
                if isPending {
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(isPending ? 0.7 : 1)
        }
    }
}

/// Claude's reply: Markdown with fenced code blocks shown as code.
private struct AssistantText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.markdown(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Segment { case prose(String), code(String) }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let block = code {
                    segments.append(.code(block.joined(separator: "\n")))
                    code = nil
                } else {
                    if !prose.isEmpty { segments.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    code = []
                }
            } else if code != nil {
                code!.append(line)
            } else {
                prose.append(line)
            }
        }
        if let block = code { segments.append(.code(block.joined(separator: "\n"))) }
        if !prose.isEmpty { segments.append(.prose(prose.joined(separator: "\n"))) }
        return segments.filter {
            if case .prose(let text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        // Headings become bold lines; everything else uses inline Markdown.
        let cleaned = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return "**\(heading)**"
            }
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(text)
    }
}

private struct ToolGroupView: View {
    let tools: [ChatMessage]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.icon(for: tools.last?.toolName ?? ""))
                        .frame(width: 16)
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if tools.count > 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(tools.count < 2)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: Self.icon(for: tool.toolName ?? "")).frame(width: 16)
                            Text(tool.toolName ?? "Tool").fontWeight(.semibold)
                            Text(tool.text).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var summary: String {
        guard let last = tools.last else { return "" }
        let current = [last.toolName, last.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return tools.count > 1 ? "\(tools.count) steps · \(current)" : current
    }

    static func icon(for tool: String) -> String {
        switch tool {
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "Question": "questionmark.bubble"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct WorkingIndicator: View {
    let label: String?
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3) { dot in
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(dot) * 0.8)))
                }
            }
            .foregroundStyle(Color.accentColor)
            Text(label ?? "Working…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Claude is working")
    }
}

// MARK: - Terminal (fallback)

/// The raw terminal screen, kept in the menu for anything the cards don't cover.
private struct TerminalSheet: View {
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
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Photos

struct PickedPhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let jpeg: Data

    /// Downscales to at most 2048 px on the long side, which is plenty for Claude, and encodes JPEG.
    init?(image: UIImage) {
        let setting = AppSettings.photoSize
        let maxSide = setting.maxSide
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: setting.jpegQuality) else { return nil }
        self.jpeg = jpeg
        thumbnail = resized.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? resized
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
