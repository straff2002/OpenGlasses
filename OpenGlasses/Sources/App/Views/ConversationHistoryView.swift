import SwiftUI

struct ConversationHistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.conversationStore.isLocked {
                ContentUnavailableView {
                    Label("Conversations Locked", systemImage: "lock.fill")
                } description: {
                    Text("Authenticate to view your encrypted conversations.")
                } actions: {
                    Button {
                        Task { await appState.conversationStore.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppAccent.aiCoral)
                }
            } else if appState.conversationStore.threads.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your voice conversations will appear here.")
                )
            } else {
                ForEach(sortedThreads) { thread in
                    NavigationLink {
                        ConversationDetailView(thread: thread)
                    } label: {
                        ThreadRow(thread: thread)
                    }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { sortedThreads[$0].id }
                    for id in ids {
                        appState.conversationStore.deleteThread(id)
                    }
                }
            }
        }
        .navigationTitle("History")
    }

    private var sortedThreads: [ConversationThread] {
        appState.conversationStore.threads.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Thread Row

private struct ThreadRow: View {
    let thread: ConversationThread

    private var displaySummary: String? {
        // Use stored summary, or generate one on-the-fly for older threads that don't have one yet
        if let summary = thread.summary, !summary.isEmpty {
            return summary
        }
        return ConversationStore.generateSummary(from: thread.messages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row
            HStack(alignment: .top) {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(thread.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Summary — the main content of the card
            if let summary = displaySummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            // Metadata pills
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

                Text(thread.mode.capitalized)
                    .font(.caption2)
                    .foregroundStyle(AppAccent.aiCoral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppAccent.aiCoral.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.title). \(displaySummary ?? ""). \(thread.messages.filter { $0.role == "user" }.count) turns. \(thread.mode) mode")
    }
}

// MARK: - Conversation Detail

struct ConversationDetailView: View {
    let thread: ConversationThread
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(thread.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding()
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        resumeConversation()
                    } label: {
                        Label("Resume", systemImage: "arrow.uturn.backward.circle")
                    }

                    ShareLink(item: threadAsText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// Resume this conversation — reload its full history into LLMService and set it as active.
    private func resumeConversation() {
        // Set this thread as the active thread in ConversationStore
        _ = appState.conversationStore.resumeThread(thread.id)

        // Replay all messages into LLMService's conversation history
        let messages = appState.conversationStore.replayMessages(for: thread.id)
        appState.llmService.loadConversationHistory(messages)

        NSLog("[History] Resumed conversation: %@ (%d messages)", thread.title, messages.count)
        dismiss()
    }

    private var threadAsText: String {
        var text = "# \(thread.title)\n"
        text += "Date: \(thread.createdAt.formatted())\n\n"
        for msg in thread.messages {
            let role = msg.role == "user" ? "You" : "AI"
            text += "**\(role)**: \(msg.content)\n\n"
        }
        return text
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                if message.imageAttached {
                    Label("Photo attached", systemImage: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(.label))
                }

                Text(message.content)
                    .font(.body)
                    .padding(12)
                    .background(message.role == "user" ? Color.blue.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.role != "user" { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role == "user" ? "You" : "AI"): \(message.content)\(message.imageAttached ? ". Photo attached" : "")")
    }
}
