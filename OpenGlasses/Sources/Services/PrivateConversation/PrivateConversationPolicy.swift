import Foundation

/// Every place a conversation is written, listed, remembered, shown or sent (Plan LU §3).
///
/// A compile-checked roster: each case is one row of the plan's table, split where the table names
/// separate writers, so `PrivateConversationPolicy.rule(for:)` has to answer for each one and a new
/// case cannot be added without a rule. P1 makes each writer consult its case before it writes.
enum ConversationSink: String, CaseIterable, Sendable {

    // MARK: The conversation store

    case storeThread
    case storeMessages
    case storeTitle
    case storeSummary
    /// The active thread id in UserDefaults, restored at launch.
    case storeActiveThreadId

    // MARK: Readers of the thread list

    /// `ConversationIndex`, fed by `saveAndProject(.messageUpsert)`.
    case recallIndex
    case sessionSearch
    case summarizeConversation
    case spotlight
    /// The Siri on-screen `NSUserActivity` in `ChatThreadView`.
    case siriOnScreenActivity
    case carPlayList
    case chatList
    /// The conversation switcher (`ConversationContinuity`).
    case conversationSwitcher

    // MARK: What runs when a thread is left

    /// The conversation timeline pass.
    case timelinePass
    /// The conversation note.
    case conversationNote
    case brainDistillOnLeave

    // MARK: Memory tags in a reply (`SemanticMemoryStore.parseAndExecuteCommands`)

    case rememberTag
    case rememberGlobalTag
    case diaryTag
    /// `[FORGET…]`. Forgetting is never blocked.
    case forgetTag

    // MARK: Other memory writers

    case memoryNudge
    case memoryLoopObserveTurn
    case memoryLoopEnrich
    case skillEvolutionNoteUserTurn
    case gatewayMemoryPush
    /// The gateway memory query (§5): not a write, but it would tell the gateway what the private
    /// conversation is about.
    case gatewayMemoryQuery

    // MARK: Tools (§4, `PrivateToolRule`)

    case memoryLikeTools
    case wearerDirectedTools

    // MARK: Prompt context built from stored data (decision 1)

    case promptMemoryBlock
    case promptPeople
    case promptJobNotes
    case promptVoiceSkills
    /// Agent Mode's `soul.md`, `skills.md` and `memory.md`.
    case promptAgentDocuments

    // MARK: Diagnostics

    /// The debug event log's transcript line. `Transcription: N characters` for every
    /// conversation (§6), so a private one needs nothing more.
    case debugEventTranscript
    /// `TurnTraceStore`'s query and result text.
    case turnTraceText
    /// `TurnTraceStore`'s timings, which carry no content.
    case turnTraceTimings
    case activityTrail

    // MARK: Photos

    /// The shutter capture a photo turn ("what's this?") takes (`CameraService.captureLibrarySink`).
    case photoTurnToLibrary
    /// "Take a photo": the photo is what the wearer asked for (decision 3).
    case explicitPhotoToLibrary

    // MARK: Glanceable surfaces

    case liveActivitySnippet
    /// The watch application context's `lastResponse`.
    case watchLastResponse
    /// The watch application context's `recentThreads`.
    case watchRecentThreads
    /// The reply to a request made on the watch, which still goes back to it.
    case watchRequestReply

    // MARK: Exports

    case shareTranscript
    case supportReport
    case agentDataExport

    // MARK: Bridges (§5)

    /// The OpenClaw session key that is stable across conversations. A private conversation uses a
    /// throwaway key made for it and dropped at its end, never this one.
    case openClawStableSessionKey
    /// The Hermes API path's `"store"` flag and `previous_response_id` chain: `false`, and no chain
    /// beyond the private conversation.
    case hermesResponseStore

    // MARK: Recognition (decision 4)

    /// Server speech recognition for a private conversation's questions. Skipped where the locale
    /// has on-device recognition; where it doesn't, server recognition is used and the explainer
    /// says so once.
    case serverSpeechRecognition
}

/// What each `ConversationSink` does while a private conversation is open (Plan LU §3).
enum PrivateConversationPolicy {

    enum Rule: Equatable, Sendable {
        /// Unchanged.
        case keep
        /// Not written, not listed and not sent.
        case skip
        /// The record is kept without its content.
        case titleOnly
        /// Shown with a fixed line in place of content.
        case placeholder(String)
    }

    /// The line the Live Activity and the watch show in place of a private reply.
    static var placeholderText: String {
        String(localized: "Private conversation",
               comment: "Shown on the Live Activity and the watch in place of the reply while a conversation is private.")
    }

    static func rule(for sink: ConversationSink) -> Rule {
        switch sink {
        case .storeThread, .storeMessages, .storeTitle, .storeSummary, .storeActiveThreadId:
            return .skip
        case .recallIndex, .sessionSearch, .summarizeConversation, .spotlight, .siriOnScreenActivity,
             .carPlayList, .chatList, .conversationSwitcher:
            return .skip
        case .timelinePass, .conversationNote, .brainDistillOnLeave:
            return .skip
        case .rememberTag, .rememberGlobalTag, .diaryTag:
            return .skip
        case .forgetTag:
            return .keep
        case .memoryNudge, .memoryLoopObserveTurn, .memoryLoopEnrich, .skillEvolutionNoteUserTurn,
             .gatewayMemoryPush, .gatewayMemoryQuery:
            return .skip
        case .memoryLikeTools:
            return .skip
        case .wearerDirectedTools:
            return .keep
        case .promptMemoryBlock, .promptPeople, .promptJobNotes, .promptVoiceSkills, .promptAgentDocuments:
            return .keep
        case .debugEventTranscript:
            return .titleOnly
        case .turnTraceText:
            return .skip
        case .turnTraceTimings:
            return .keep
        case .activityTrail:
            return .titleOnly
        case .photoTurnToLibrary:
            return .skip
        case .explicitPhotoToLibrary:
            return .keep
        case .liveActivitySnippet, .watchLastResponse:
            return .placeholder(placeholderText)
        case .watchRecentThreads:
            return .skip
        case .watchRequestReply:
            return .keep
        case .shareTranscript, .supportReport, .agentDataExport:
            return .skip
        case .openClawStableSessionKey, .hermesResponseStore:
            return .skip
        case .serverSpeechRecognition:
            return .skip
        }
    }
}
