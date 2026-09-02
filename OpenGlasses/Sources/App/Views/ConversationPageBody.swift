import SwiftUI

/// What sits under the conversation page's header: the conversation, or the live turn.
///
/// The page used to be able to draw only the live turn — two cards built from
/// `AppState.currentTranscription` and `AppState.lastResponse`. Those are *turn* state, and
/// resuming a thread touches neither, so picking a conversation out of the switcher produced an
/// active thread with nothing on screen and, on a fresh launch, the empty state under it. The
/// thread was genuinely active and the model genuinely had its history; the page simply never
/// rendered a stored message. `ConversationContinuity.PageContent` is the decision, held apart
/// from the view so both halves are provable without a screen.
struct ConversationPageBody: View {
    @EnvironmentObject var appState: AppState
    /// Observed directly — a nested `ObservableObject`'s changes don't republish through
    /// `appState`, and this view's whole job is to follow the store.
    @ObservedObject var store: ConversationStore
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    private var liveUserText: String {
        switch appState.currentMode {
        case .geminiLive: return session.userTranscript
        case .openaiRealtime: return openAISession.userTranscript
        case .direct: return appState.currentTranscription
        }
    }

    private var liveAssistantText: String {
        switch appState.currentMode {
        case .geminiLive: return session.aiTranscript
        case .openaiRealtime: return openAISession.aiTranscript
        case .direct: return appState.lastResponse
        }
    }

    private var content: ConversationContinuity.PageContent {
        ConversationContinuity.pageContent(
            store: store,
            isRealtimeSession: isRealtime,
            liveUserText: liveUserText,
            liveAssistantText: liveAssistantText)
    }

    var body: some View {
        switch content {
        case .history(let threadId):
            ConversationThreadTranscript(store: store, threadId: threadId)
        case .liveTurn, .empty:
            // `TranscriptOverlay` owns the live cards and the empty copy, and keeps owning them:
            // in a realtime session it is the only honest view, and before the first turn is
            // persisted it is the only thing there is to draw.
            ScrollView(.vertical) {
                TranscriptOverlay(session: session, openAISession: openAISession)
                    .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// One conversation, on the dock's glass: every message in it, scrolled to the newest, with the
/// in-flight reply appending below.
///
/// The same `MessageBubble` the Chat tab draws — a reply that looked different depending on which
/// surface you read it from would be two designs for one conversation. What differs is the frame:
/// this one lives inside a fixed-height page of a horizontally-paging panel, so it scrolls
/// vertically and adds no gesture of its own. That is the axis rule the panel's edit page follows
/// too: a vertical scroll is not a competing gesture, and a *drag* would be.
struct ConversationThreadTranscript: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: ConversationStore
    let threadId: String

    private let bottomAnchor = "dock-conversation-bottom"

    private var thread: ConversationThread? { store.threads.first { $0.id == threadId } }
    private var isThinking: Bool { appState.isProcessing && store.activeThreadId == threadId }

    /// The reply currently streaming into *this* thread, if any.
    private var streamingText: String? {
        guard let turn = appState.streamingTurn, turn.threadId == threadId,
              !turn.text.isEmpty else { return nil }
        return turn.text
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(thread?.messages ?? []) { message in
                        MessageBubble(message: message)
                    }
                    if let streamingText {
                        StreamingBubble(text: streamingText)
                    } else if isThinking {
                        TypingIndicator()
                    }
                    // The scroll target. A one-point spacer rather than the last bubble, so a
                    // reply that is still growing keeps its own bottom in view.
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: thread?.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: isThinking) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy) }
            // The newest message is the one being read, and switching threads has to land on it
            // rather than at the top of somebody's afternoon.
            .onChange(of: threadId) { _, _ in scrollToBottom(proxy, animated: false) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard animated else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}
