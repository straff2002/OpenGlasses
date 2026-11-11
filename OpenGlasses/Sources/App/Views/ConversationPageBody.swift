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
        case .openaiRealtime, .openaiCompatibleRealtime: return openAISession.userTranscript
        case .direct: return appState.currentTranscription
        }
    }

    private var liveAssistantText: String {
        switch appState.currentMode {
        case .geminiLive: return session.aiTranscript
        case .openaiRealtime, .openaiCompatibleRealtime: return openAISession.aiTranscript
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
        VStack(spacing: 4) {
            ManualSelectionButton(store: store, threadID: store.activeThreadId)
            conversationContent
        }
    }

    @ViewBuilder
    private var conversationContent: some View {
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

/// One conversation in a frame of its own (the expanded workspace's context pane): every message in
/// it, scrolled to the newest, with the in-flight reply appending below.
///
/// The same `MessageBubble` the Chat tab draws — a reply that looked different depending on which
/// surface you read it from would be two designs for one conversation.
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
                VStack(spacing: 0) {
                    ConversationThreadMessages(store: store, threadId: threadId)
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
            // The same doors the Chat tab draws under an answer (Plan EK P3).
            .environment(\.citationOpener, appState.citationOpener)
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

/// One thread's messages, with the in-flight reply appending below — the rows without a frame, so a
/// page that scrolls by itself and the Voice tab's feed draw the same thing.
struct ConversationThreadMessages: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: ConversationStore
    let threadId: String

    private var thread: ConversationThread? { store.threads.first { $0.id == threadId } }
    private var isThinking: Bool { appState.isProcessing && store.activeThreadId == threadId }

    private var streamingText: String? {
        guard let turn = appState.streamingTurn, turn.threadId == threadId,
              !turn.text.isEmpty else { return nil }
        return turn.text
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(thread?.messages ?? []) { message in
                MessageBubble(message: message)
            }
            if let streamingText {
                StreamingBubble(text: streamingText)
            } else if isThinking {
                TypingIndicator()
            }
        }
    }
}

/// The Voice tab's one scroll: whatever leads in (My Day, captions, notices), the conversation as
/// long as it is, and whatever follows it — the manual page an answer cited, read in place.
///
/// The conversation used to live in a fixed-height page of the dock, a window a few lines tall.
/// Here it is the tab's own scroll view, so it runs to its full length and the tab bar shrinks to
/// the mark as it scrolls back through it.
struct ConversationFeed<Lead: View, Trail: View>: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: ConversationStore
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    /// Changes when what follows the conversation does (a manual page opening), so the feed can
    /// bring it into view.
    var trailID: String? = nil
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trail: () -> Trail

    private let bottomAnchor = "voice-feed-bottom"

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    private var liveUserText: String {
        switch appState.currentMode {
        case .geminiLive: return session.userTranscript
        case .openaiRealtime, .openaiCompatibleRealtime: return openAISession.userTranscript
        case .direct: return appState.currentTranscription
        }
    }

    private var liveAssistantText: String {
        switch appState.currentMode {
        case .geminiLive: return session.aiTranscript
        case .openaiRealtime, .openaiCompatibleRealtime: return openAISession.aiTranscript
        case .direct: return appState.lastResponse
        }
    }

    private var content: ConversationContinuity.PageContent {
        ConversationContinuity.pageContent(
            store: store, isRealtimeSession: isRealtime,
            liveUserText: liveUserText, liveAssistantText: liveAssistantText)
    }

    private var threadId: String? {
        if case .history(let id) = content { return id }
        return nil
    }

    private var messageCount: Int {
        guard let threadId else { return 0 }
        return store.threads.first { $0.id == threadId }?.messages.count ?? 0
    }

    private var streamingLength: Int { appState.streamingTurn?.text.count ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    lead()
                    VStack(spacing: 4) {
                        ManualSelectionButton(store: store, threadID: store.activeThreadId)
                        switch content {
                        case .history(let id):
                            ConversationThreadMessages(store: store, threadId: id)
                        case .liveTurn, .empty:
                            // `TranscriptOverlay` owns the live cards and the empty copy: in a
                            // realtime session it is the only honest view, and before the first
                            // turn is persisted it is the only thing there is to draw.
                            TranscriptOverlay(session: session, openAISession: openAISession)
                        }
                    }
                    .padding(.horizontal, 16)
                    trail()
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
            }
            // Short content sits at the top — the day card and the things to try stay up there,
            // with the conversation following on under them — while a conversation longer than
            // the screen opens on, and keeps to, its newest line.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // No size-change anchor: the viewport changes size when the tab bar tucks away and
            // comes back, and anchoring to that moved the line being read. New lines are followed
            // by the explicit scrolls below instead.
            .onChange(of: messageCount) { _, _ in scrollToBottom(proxy) }
            .onChange(of: appState.isProcessing) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingLength) { _, _ in scrollToBottom(proxy) }
            .onChange(of: liveAssistantText) { _, _ in scrollToBottom(proxy) }
            .onChange(of: trailID) { _, _ in scrollToBottom(proxy) }
            .onChange(of: threadId) { _, _ in scrollToBottom(proxy, animated: false) }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .environment(\.citationOpener, appState.citationOpener)
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
