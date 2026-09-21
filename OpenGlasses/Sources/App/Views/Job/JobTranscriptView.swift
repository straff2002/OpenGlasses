import SwiftUI

/// A finished job's conversation, **read-only** (Plan FO P2).
///
/// Deliberately not `ChatThreadView`. That view activates the thread it is showing the moment it
/// appears — it is the live chat surface, and that is correct there — which would make a past job's
/// conversation the one the next spoken turn lands in, purely because somebody looked at it. A
/// technician reviewing last Tuesday's job and then saying something to the glasses would have
/// appended it to last Tuesday.
///
/// So this renders the stored messages and nothing else: no composer, no activation, no
/// `activeThreadId`. The bubbles are the shipped ones, without the edit and regenerate actions,
/// because those write.
struct JobTranscriptView: View {
    let threadId: String

    @EnvironmentObject private var appState: AppState

    private var thread: ConversationThread? {
        appState.conversationStore.threads.first { $0.id == threadId }
    }

    var body: some View {
        Group {
            if appState.conversationStore.isLocked {
                ContentUnavailableView {
                    Label("Conversations Locked", systemImage: "lock.fill")
                } description: {
                    Text("Authenticate in the Chat tab to read this job's conversation.")
                }
            } else if let thread, !thread.messages.isEmpty {
                transcript(thread)
            } else {
                ContentUnavailableView {
                    Label("Nothing was said on this job", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Its conversation is not on the device any more, or no turn was ever saved against it.")
                }
            }
        }
        .navigationTitle(thread?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transcript(_ thread: ConversationThread) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Text("Read-only — this conversation belongs to a finished job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ForEach(thread.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(.vertical, 8)
        }
        .background(OGTheme.canvas)
    }
}
