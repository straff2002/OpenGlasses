import SwiftUI

struct ConversationHistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.conversationStore.threads.isEmpty {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(thread.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(thread.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label("\(thread.messages.count)", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if thread.messages.contains(where: { $0.imageAttached }) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }

                Text(thread.mode.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }

            if let lastMessage = thread.messages.last {
                Text(lastMessage.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Conversation Detail

struct ConversationDetailView: View {
    let thread: ConversationThread

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
                ShareLink(item: threadAsText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
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
                        .foregroundStyle(.tint)
                }

                Text(message.content)
                    .font(.body)
                    .padding(12)
                    .background(message.role == "user" ? Color.blue.opacity(0.15) : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.role != "user" { Spacer(minLength: 60) }
        }
    }
}
