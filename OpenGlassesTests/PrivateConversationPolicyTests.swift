import XCTest
@testable import OpenGlasses

/// Plan LU P0 §3 — every place a conversation goes has a rule for a private one, and the rules are
/// the plan's table.
final class PrivateConversationPolicyTests: XCTestCase {

    private typealias Rule = PrivateConversationPolicy.Rule

    /// The §3 table, row by row. Written out here rather than derived, so a change to the policy
    /// has to change this too.
    private var expected: [ConversationSink: Rule] {
        let placeholder = Rule.placeholder(PrivateConversationPolicy.placeholderText)
        return [
            // Conversation store: thread, messages, title, summary, active-thread id.
            .storeThread: .skip, .storeMessages: .skip, .storeTitle: .skip, .storeSummary: .skip,
            .storeActiveThreadId: .skip,
            // Recall index, session_search, summarize_conversation, Spotlight, Siri, CarPlay, Chat
            // list, switcher.
            .recallIndex: .skip, .sessionSearch: .skip, .summarizeConversation: .skip, .spotlight: .skip,
            .siriOnScreenActivity: .skip, .carPlayList: .skip, .chatList: .skip,
            .conversationSwitcher: .skip,
            // The timeline pass, the conversation note, brain distillation on leave.
            .timelinePass: .skip, .conversationNote: .skip, .brainDistillOnLeave: .skip,
            // REMEMBER, REMEMBER_GLOBAL and DIARY tags; FORGET still works.
            .rememberTag: .skip, .rememberGlobalTag: .skip, .diaryTag: .skip, .forgetTag: .keep,
            // Memory nudge, the memory loop, skill evolution, gateway memory push (and query, §5).
            .memoryNudge: .skip, .memoryLoopObserveTurn: .skip, .memoryLoopEnrich: .skip,
            .skillEvolutionNoteUserTurn: .skip, .gatewayMemoryPush: .skip, .gatewayMemoryQuery: .skip,
            // Memory-like tools refused; tools the wearer names run (§4, decision 2).
            .memoryLikeTools: .skip, .wearerDirectedTools: .keep,
            // Prompt context read as usual (decision 1).
            .promptMemoryBlock: .keep, .promptPeople: .keep, .promptJobNotes: .keep,
            .promptVoiceSkills: .keep, .promptAgentDocuments: .keep,
            // Diagnostics.
            .debugEventTranscript: .titleOnly, .turnTraceText: .skip, .turnTraceTimings: .keep,
            .activityTrail: .titleOnly,
            // Photos (decision 3).
            .photoTurnToLibrary: .skip, .explicitPhotoToLibrary: .keep,
            // Live Activity and watch.
            .liveActivitySnippet: placeholder, .watchLastResponse: placeholder,
            .watchRecentThreads: .skip, .watchRequestReply: .keep,
            // Share transcript, support report, AgentDataExporter.
            .shareTranscript: .skip, .supportReport: .skip, .agentDataExport: .skip,
            // Bridges (§5).
            .openClawStableSessionKey: .skip, .hermesResponseStore: .skip,
            // Recognition (decision 4).
            .serverSpeechRecognition: .skip,
        ]
    }

    func testEverySinkHasARule() {
        for sink in ConversationSink.allCases {
            XCTAssertNotNil(expected[sink], "\(sink) is missing from the §3 table in this test")
        }
        XCTAssertEqual(Set(expected.keys), Set(ConversationSink.allCases))
    }

    func testTheRulesMatchThePlansTable() {
        for sink in ConversationSink.allCases {
            XCTAssertEqual(PrivateConversationPolicy.rule(for: sink), expected[sink], "\(sink)")
        }
    }

    /// The placeholder is user-facing words, never the reply, and never an internal name.
    func testThePlaceholderSaysPrivateConversation() {
        let text = PrivateConversationPolicy.placeholderText
        XCTAssertFalse(text.isEmpty)
        if Locale.current.language.languageCode?.identifier == "en" {
            XCTAssertEqual(text, "Private conversation")
        }
        XCTAssertNil(text.range(of: #"\bPlan\b|\bLU\b"#, options: .regularExpression))
    }

    /// Forgetting is never blocked, and nothing that keeps memory is kept.
    func testForgettingIsKeptAndMemoryWritersAreNot() {
        XCTAssertEqual(PrivateConversationPolicy.rule(for: .forgetTag), .keep)
        for sink: ConversationSink in [.rememberTag, .rememberGlobalTag, .diaryTag, .memoryNudge,
                                       .memoryLoopObserveTurn, .memoryLoopEnrich,
                                       .skillEvolutionNoteUserTurn, .gatewayMemoryPush,
                                       .brainDistillOnLeave, .memoryLikeTools] {
            XCTAssertEqual(PrivateConversationPolicy.rule(for: sink), .skip, "\(sink)")
        }
    }
}
