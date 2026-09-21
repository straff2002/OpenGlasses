import SwiftUI

/// The conversation page's other half: which conversation this is, how to start a new one, and how
/// to get back into an earlier one.
///
/// The page used to be a transcript and nothing else, which was fine while a reply was arriving and
/// useless the moment it finished — the voice session ends its thread when it returns to the wake
/// word, so the conversation on screen was one nobody could add to any more, with no way to say so
/// and no way to pick it back up. Naming the active thread and offering it back is the whole fix.
struct ConversationPageHeader: View {
    @EnvironmentObject var appState: AppState
    /// Observed directly: a nested `ObservableObject`'s changes don't republish through
    /// `appState`, so without this the header would keep naming a thread that had already ended.
    @ObservedObject var store: ConversationStore
    @Environment(\.appAccent) private var accent

    @State private var showingSwitcher = false
    /// Raised when starting a new conversation would take the technician out of an open job.
    @State private var pendingLeaveJob: JobThreadQuestion?

    private var title: String { ConversationContinuity.headerTitle(for: store) }
    private var hasThreads: Bool { !store.threads.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showingSwitcher = true
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isLocked)
            .accessibilityLabel("Conversation: \(title)")
            .accessibilityHint(hasThreads
                               ? "Double-tap to switch to an earlier conversation."
                               : "No earlier conversations yet.")

            Spacer(minLength: 4)

            // Only while nothing is active, which is exactly the state a finished voice turn
            // leaves behind. Without it the conversation just read is unreachable in one gesture.
            if let resumable = ConversationContinuity.resumableThread(in: store) {
                Button {
                    resume(resumable.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel("Carry on with \(resumable.title)")
                .accessibilityHint("Picks the last conversation back up, with everything already said in context.")
            }

            Button {
                newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.footnote.weight(.semibold))
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .disabled(store.isLocked)
            .accessibilityLabel("New conversation")
            .accessibilityHint("Ends this one. What you say next starts a fresh conversation.")
        }
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OGTheme.card)
        )
        .sheet(isPresented: $showingSwitcher) {
            ConversationSwitcherSheet(store: store)
                .environmentObject(appState)
        }
        .jobThreadQuestionAlert($pendingLeaveJob) { asked in
            switch asked.requested {
            case .newChat:
                appState.guidedJobFlow.requestNewChat(confirmed: true)
            case .switchThread(let id):
                appState.activateConversationThread(id, confirmed: true)
            }
        }
    }

    /// End the current thread cleanly and clear the model's context, so the next thing said
    /// starts somewhere new. Nothing is deleted — the thread it ends is in the switcher and in
    /// the Chat tab a moment later.
    /// The two-step resume, through the one seam the Chat tab also uses.
    private func resume(_ threadId: String) {
        if let question = appState.activateConversationThread(threadId) {
            pendingLeaveJob = question
        }
    }

    private func newConversation() {
        // Through the job chokepoint (Plan FO P1): with a job running this is the one tap that can
        // take the technician out of the job's conversation, so it asks first rather than silently
        // leaving it. With no job it does exactly what it always did.
        if let question = appState.guidedJobFlow.requestNewChat() {
            pendingLeaveJob = question
        }
    }
}

// MARK: - Switcher

/// Recent conversations: pick one to carry on with, or delete one — or all of them.
///
/// A sheet rather than a menu because two of the three things it does need rows: a swipe needs
/// something to swipe, and a date needs somewhere to sit.
struct ConversationSwitcherSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss

    @State private var pendingDeletion: ConversationContinuity.DeletionScope?
    @State private var pendingLeaveJob: JobThreadQuestion?

    private var threads: [ConversationThread] { ConversationContinuity.recentThreads(in: store) }

    var body: some View {
        NavigationStack {
            Group {
                if threads.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Talk to your glasses or type a message, and it will show up here.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !threads.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) {
                            pendingDeletion = ConversationContinuity.deleteAllScope(in: store)
                        }
                    }
                }
            }
            .alert(pendingDeletion?.confirmTitle ?? "",
                   isPresented: Binding(get: { pendingDeletion != nil },
                                        set: { if !$0 { pendingDeletion = nil } }),
                   presenting: pendingDeletion) { scope in
                Button(scope.confirmButton, role: .destructive) {
                    ConversationContinuity.delete(scope, confirmed: true, in: store)
                }
                Button("Cancel", role: .cancel) {}
            } message: { scope in
                Text(scope.confirmMessage)
            }
            // Picking another conversation out of the switcher is one of the taps that could have
            // walked a technician out of their job without saying so (Plan FO P1).
            .jobThreadQuestionAlert($pendingLeaveJob) { asked in
                if case .switchThread(let id) = asked.requested {
                    appState.activateConversationThread(id, confirmed: true)
                    dismiss()
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(threads) { thread in
                    Button {
                        resume(thread)
                    } label: {
                        row(thread)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            pendingDeletion = ConversationContinuity.deletionScope(forThread: thread)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ConversationContinuity.spokenLabel(
                        for: thread, activeThreadId: store.activeThreadId))
                    .accessibilityHint("Double-tap to carry on with this conversation.")
                    // A swipe leaves no mark in the accessibility tree, so delete is also a
                    // named action — the only way to reach it without sight.
                    .accessibilityActions {
                        Button("Delete conversation") {
                            pendingDeletion = ConversationContinuity.deletionScope(forThread: thread)
                        }
                    }
                }
            } footer: {
                Text("Picking a conversation makes it the one you're in — what you say next carries on from where it left off, with everything already said in context.")
            }
        }
    }

    private func row(_ thread: ConversationThread) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                Text(thread.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if thread.id == store.activeThreadId {
                Text("Current")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }

    /// Switching is explicit and it is the two-step resume: the store learns where the next turn
    /// lands, and the model is handed that thread's history so the conversation actually
    /// continues rather than restarting inside an old transcript.
    private func resume(_ thread: ConversationThread) {
        if let question = appState.activateConversationThread(thread.id) {
            pendingLeaveJob = question
            return
        }
        dismiss()
    }
}

// MARK: - The app's side of the seam

extension AppState {
    /// Make `threadId` the thread the next turn appends to, with its history in the model's
    /// context. The Chat tab and the dock's conversation page both call this, so "resume" means
    /// one thing in the app rather than two similar things in two files.
    ///
    /// Plan FO P1: while a job owns the open conversation, opening a different one is a question
    /// rather than a silent switch. The question comes back for the caller to present; passing
    /// `confirmed` performs the switch and releases the job's hold on its thread. With no job
    /// running this is the two-step resume it always was.
    @discardableResult
    func activateConversationThread(_ threadId: String, confirmed: Bool = false) -> JobThreadQuestion? {
        guidedJobFlow.requestResume(threadId: threadId, confirmed: confirmed)
    }
}
