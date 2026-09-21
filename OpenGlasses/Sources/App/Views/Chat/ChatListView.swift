import SwiftUI

/// Chat tab root — a list of conversation threads plus a live, continuable chat view.
/// Subsumes the old read-only History tab: tap a thread to keep chatting, or start a new one.
struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [String] = []
    /// When on, the list shows only the active project's (Persona's) threads (Plan AN).
    @State private var projectScoped = false
    /// Raised when "New chat" would take the technician out of an open job (Plan FO P1).
    @State private var pendingLeaveJob: JobThreadQuestion?

    private var store: ConversationStore { appState.conversationStore }
    private var activeProjectId: String? { appState.activePersona?.id }
    private var activeProjectName: String? { appState.activePersona?.name }

    private var sortedThreads: [ConversationThread] {
        let base = (projectScoped && activeProjectId != nil)
            ? store.threads(forPersona: activeProjectId)
            : store.threads
        return base.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isLocked {
                    lockedView
                } else if store.threads.isEmpty {
                    emptyView
                } else {
                    threadList
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                if let activeProjectName, !store.isLocked {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Scope", selection: $projectScoped) {
                                Text("All conversations").tag(false)
                                Text("\(activeProjectName) only").tag(true)
                            }
                        } label: {
                            Label(projectScoped ? activeProjectName : "All",
                                  systemImage: projectScoped ? "folder.fill" : "tray.full")
                        }
                        .accessibilityLabel("Filter conversations by project")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await startNewChat() } } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .disabled(store.isLocked)
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatThreadView(threadId: id)
            }
        }
        .onChange(of: sortedThreads.map(\.id), initial: true) { _, _ in
            // Structure only: no thread ids, titles, or conversation content leave the store.
            // This gives a future UIKit list assertion the row count and active screen that the
            // TestFlight crash report itself omits.
            PrivacyLog.app(.listUpdated, detail: PrivacyToken("ChatListView"),
                           count: sortedThreads.count)
        }
        .jobThreadQuestionAlert($pendingLeaveJob) { _ in
            appState.guidedJobFlow.confirmLeaveJobThread()
            Task { await performNewChat() }
        }
        // A conversation another tab asked to show — the Job tab's "Open conversation" (Plan FO
        // P2). `initial: true` because a tab's content is built lazily: the request is usually
        // already standing by the time this view first appears.
        //
        // Nothing here changes which thread is active. Whoever set this has already been through
        // `GuidedJobFlow`, which resumed the thread properly — id *and* history — and this only
        // puts the page in front of the wearer.
        .onChange(of: appState.chatThreadToOpen, initial: true) { _, requested in
            guard let requested, store.threads.contains(where: { $0.id == requested }) else { return }
            if path.last != requested { path.append(requested) }
            appState.chatThreadToOpen = nil
        }
    }

    private var threadList: some View {
        List {
            ForEach(sortedThreads) { thread in
                NavigationLink(value: thread.id) {
                    ThreadRow(thread: thread)
                }
            }
            .onDelete { indexSet in
                indexSet.map { sortedThreads[$0].id }.forEach { store.deleteThread($0) }
            }
        }
        .ogFormStyle()
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a chat — works with or without your glasses.")
        } actions: {
            Button { Task { await startNewChat() } } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var lockedView: some View {
        ContentUnavailableView {
            Label("Conversations Locked", systemImage: "lock.fill")
        } description: {
            Text("Authenticate to view your encrypted conversations.")
        } actions: {
            Button {
                Task { await store.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// The UI's new-conversation action is a conversation reset like any other, so it goes through
    /// the same coordinator as the spoken command and the model's tool call. Starting a thread here
    /// on its own would make a blank page while every backend — a live session, the gateway agent —
    /// carried on remembering the conversation the wearer just left.
    private func startNewChat() async {
        // A job owns its conversation, so "New chat" asks before it walks out of one (Plan FO P1).
        // The reset itself is untouched — only the question is new.
        if let question = appState.guidedJobFlow.leaveJobThreadQuestion() {
            pendingLeaveJob = question
            return
        }
        await performNewChat()
    }

    private func performNewChat() async {
        let report = await appState.conversationReset.requestReset(source: .userInterface)
        // No thread on the held-back path: the coordinator did not retire anything, and a fresh
        // page would be the exact false confirmation this routing exists to avoid.
        guard report.didRetireLocalContext, let threadId = store.activeThreadId else { return }
        path.append(threadId)
    }
}

// MARK: - Thread Row

private struct ThreadRow: View {
    let thread: ConversationThread

    private var displaySummary: String? {
        if let summary = thread.summary, !summary.isEmpty { return summary }
        return ConversationStore.generateSummary(from: thread.messages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(thread.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = displaySummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                let turnCount = thread.messages.filter { $0.role == "user" }.count
                Label("\(turnCount) turn\(turnCount == 1 ? "" : "s")", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if thread.messages.contains(where: { $0.imageAttached }) {
                    Label("Photos", systemImage: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                OGChip(text: thread.mode.capitalized)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.title). \(displaySummary ?? ""). \(thread.messages.filter { $0.role == "user" }.count) turns. \(thread.mode) mode")
    }
}
