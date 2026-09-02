import SwiftUI
import Combine
import PDFKit
import UniformTypeIdentifiers

/// A live, continuable conversation thread — scrollable message history + a docked composer.
/// This is where a glasses-off user lives: type, get an answer rendered with markdown/code,
/// keep going. Reads/writes through `ConversationStore` + `AppState.sendTextMessage`.
struct ChatThreadView: View {
    let threadId: String

    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didResume = false
    @State private var speakReplies = false
    @State private var showModelPicker = false
    @State private var showPersonaPicker = false
    @State private var showFileImporter = false
    @State private var editingMessageId: String?
    @State private var editingText = ""
    @State private var attachNotice: String?

    private let bottomAnchor = "chat-bottom"

    private var store: ConversationStore { appState.conversationStore }
    private var thread: ConversationThread? { store.threads.first { $0.id == threadId } }
    private var isThinking: Bool { appState.isProcessing && store.activeThreadId == threadId }

    /// The live, partially-streamed reply for this thread (on-device provider), if any.
    private var streamingText: String? {
        guard let turn = appState.streamingTurn, turn.threadId == threadId,
              !turn.text.isEmpty else { return nil }
        return turn.text
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let attachNotice { noticeBanner(attachNotice) }
            if !Config.conversationPersistenceEnabled { persistenceBanner }

            Divider()
            ChatComposer(
                autoFocus: thread?.messages.isEmpty ?? false,
                onAttachDocument: { showFileImporter = true }
            ) { text, image in
                send(text, image)
            }
        }
        .navigationTitle(thread?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        // Plan BQ P3: let Siri resolve "this" to the open thread (titles/summary only —
        // same shape the Spotlight index donates; hipaaMode disables inside the modifier).
        .siriOnscreenContent(thread.map { thread in
            GlassesContentEntity(record: IndexableRecord(
                contentType: .conversation,
                itemId: thread.id,
                title: thread.title,
                text: thread.summary ?? "",
                keywords: [],
                date: thread.updatedAt
            ))
        })
        .toolbar { toolbarContent }
        .onAppear(perform: resumeIfNeeded)
        .onDisappear(perform: pruneIfEmpty)
        .sheet(isPresented: $showModelPicker, onDismiss: reloadHistory) {
            ModelPickerSheet(appState: appState)
        }
        .sheet(isPresented: $showPersonaPicker, onDismiss: reloadHistory) {
            PersonaPickerSheet(appState: appState)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Edit message", isPresented: editingBinding) {
            TextField("Message", text: $editingText)
            Button("Send", action: commitEdit)
            Button("Cancel", role: .cancel) { editingMessageId = nil }
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editingMessageId != nil }, set: { if !$0 { editingMessageId = nil } })
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let thread, !thread.messages.isEmpty {
                        ForEach(thread.messages) { message in
                            MessageBubble(
                                message: message,
                                onEdit: message.role == "user" ? { beginEdit(message) } : nil,
                                onRegenerate: isLastAssistant(message) ? { regenerate() } : nil
                            )
                        }
                    } else {
                        emptyPrompt
                    }
                    if let streamingText {
                        StreamingBubble(text: streamingText)
                    } else if isThinking {
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding()
            }
            .onChange(of: thread?.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: isThinking) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(accent)
            Text("Ask anything")
                .font(.headline)
            Text("Type below — works with or without your glasses.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var persistenceBanner: some View {
        Text("Conversation history is off — messages won't be saved. Enable it in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
    }

    private func noticeBanner(_ text: String) -> some View {
        OGNotice(text: text, systemImage: "paperclip")
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .transition(.opacity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $speakReplies) { Label("Speak replies", systemImage: "speaker.wave.2") }
                Button { showModelPicker = true } label: { Label("Switch model", systemImage: "cpu") }
                Button { showPersonaPicker = true } label: { Label("Switch persona", systemImage: "person.2") }
                if let thread, !thread.messages.isEmpty {
                    ShareLink(item: Self.threadAsText(thread)) { Label("Share transcript", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Chat options")
        }
    }

    // MARK: - Actions

    private func isLastAssistant(_ message: ConversationMessage) -> Bool {
        message.role == "assistant" && message.id == thread?.messages.last?.id && !appState.isProcessing
    }

    private func resumeIfNeeded() {
        guard !didResume else { return }
        didResume = true
        activateThread()
    }

    /// Make this thread the one new messages append to, and load its history into the LLM context.
    /// One seam, shared with the dock's conversation page — resuming has to mean the same thing
    /// wherever it is asked for.
    private func activateThread() {
        appState.activateConversationThread(threadId)
    }

    private func send(_ text: String, _ image: Data?) {
        activateThread()
        Task {
            await appState.sendTextMessage(text, imageData: image, speakResponse: speakReplies)
            store.applyAutoTitleIfNeeded(threadId)
        }
    }

    /// Reload this thread's history into the LLM context — used after switching model/persona
    /// (which may clear the LLM's in-memory history) so the conversation keeps its context.
    private func reloadHistory() {
        appState.llmService.loadConversationHistory(store.replayMessages(for: threadId))
    }

    /// Re-run the last reply: drop the last user+assistant pair and resend the user's text.
    private func regenerate() {
        guard !appState.isProcessing, let thread,
              let lastUser = thread.messages.last(where: { $0.role == "user" }) else { return }
        let text = lastUser.content
        activateThread()
        store.truncate(from: lastUser.id, in: threadId)
        reloadHistory()
        Task {
            await appState.sendTextMessage(text, speakResponse: speakReplies)
            store.applyAutoTitleIfNeeded(threadId)
        }
    }

    private func beginEdit(_ message: ConversationMessage) {
        guard !appState.isProcessing else { return }
        editingMessageId = message.id
        editingText = message.content
    }

    /// Commit an edit: truncate the thread from the edited message and resend the new text.
    private func commitEdit() {
        guard let id = editingMessageId else { return }
        editingMessageId = nil
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !appState.isProcessing else { return }
        activateThread()
        store.truncate(from: id, in: threadId)
        reloadHistory()
        Task {
            await appState.sendTextMessage(text, speakResponse: speakReplies)
            store.applyAutoTitleIfNeeded(threadId)
        }
    }

    // MARK: - Document attach (chat over your files)

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await ingestDocument(url) }
    }

    private func ingestDocument(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let (name, text) = Self.extractText(from: url), !text.isEmpty else {
            showNotice("Couldn't read that file.")
            return
        }
        attachNotice = "Indexing \(name)…"
        let ref = await appState.documentStore.ingest(name: name, text: text)
        showNotice(ref != nil ? "📎 \(name) added — ask me about it." : "Couldn't index \(name).")
    }

    private func showNotice(_ text: String) {
        attachNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if attachNotice == text { attachNotice = nil }
        }
    }

    /// Extract text from a PDF (PDFKit) or a UTF-8 text/CSV file. No OCR — scanned PDFs yield empty.
    private static func extractText(from url: URL) -> (name: String, text: String)? {
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { return nil }
            return (name, doc.string ?? "")
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return (name, text)
        }
        return nil
    }

    /// Drop a thread the user opened but never used, so empty "New Conversation" shells
    /// don't accumulate in the list.
    private func pruneIfEmpty() {
        if let thread, thread.messages.isEmpty { store.deleteThread(threadId) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private static func threadAsText(_ thread: ConversationThread) -> String {
        var text = "# \(thread.title)\n"
        text += "Date: \(thread.createdAt.formatted())\n\n"
        for msg in thread.messages {
            let role = msg.role == "user" ? "You" : "AI"
            text += "**\(role)**: \(msg.content)\n\n"
        }
        return text
    }
}

/// Assistant bubble for an in-flight, streaming reply (on-device provider). Mirrors the
/// assistant side of `MessageBubble` but renders live partial text with no timestamp.
///
/// Shared with the dock's conversation page, like `MessageBubble` beside it: the two surfaces
/// render the same conversation and a reply that looked different depending on which one you were
/// looking at would be two designs for one thing.
struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            MessageContentView(text: text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 48)
        }
        .accessibilityLabel("AI is replying: \(text)")
    }
}

/// Three-dot "assistant is thinking" indicator shown while a reply is in flight. Shared with the
/// dock's conversation page.
struct TypingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 7, height: 7)
                    // Reduce Motion holds the three dots still: what they say is
                    // "a reply is coming", and the travelling dot isn't carrying it.
                    .opacity(reduceMotion ? 0.6 : (phase == i ? 1 : 0.3))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Assistant is typing")
    }
}
