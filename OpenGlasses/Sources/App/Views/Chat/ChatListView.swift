import SwiftUI

/// Chat tab root — a list of conversation threads plus a live, continuable chat view.
/// Subsumes the old read-only History tab: tap a thread to keep chatting, or start a new one.
struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [String] = []
    /// When on, the list shows only the active project's (Persona's) threads (Plan AN).
    @State private var projectScoped = false

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
                    Button(action: startNewChat) {
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
            Button(action: startNewChat) {
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

    private func startNewChat() {
        let thread = store.startThread(mode: appState.currentMode.rawValue, personaId: activeProjectId)
        path.append(thread.id)
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
