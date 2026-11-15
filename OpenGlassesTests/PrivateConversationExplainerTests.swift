import XCTest
@testable import OpenGlasses

/// Plan LU P1b — the phone's words for a private conversation, and what its conversation page
/// draws: the explainer shown once, its server-recognition line, and the private transcript in the
/// stored thread's place.
@MainActor
final class PrivateConversationExplainerTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "PrivateConversationExplainerTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        PrivateConversationGate.setActive(false)
        super.tearDown()
    }

    // MARK: - The explainer

    func testTheExplainerIsThePlansSentence() {
        XCTAssertEqual(PrivateConversationExplainer.text,
                       "Private conversations aren't saved, listed or remembered, and leave no notes. The AI service you use still receives what you say, as it does for every conversation.")
    }

    func testItIsShownOncePerPhone() {
        XCTAssertTrue(PrivateConversationExplainer.takeFirstShowing(defaults: defaults))
        XCTAssertFalse(PrivateConversationExplainer.takeFirstShowing(defaults: defaults))
        XCTAssertFalse(PrivateConversationExplainer.takeFirstShowing(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: PrivateConversationExplainer.shownKey))
    }

    func testTheServerRecognitionLineIsAddedOnlyWhereTheLanguageNeedsIt() {
        XCTAssertEqual(PrivateConversationExplainer.message(localeSupportsOnDevice: true),
                       PrivateConversationExplainer.text)
        let server = PrivateConversationExplainer.message(localeSupportsOnDevice: false)
        XCTAssertTrue(server.hasPrefix(PrivateConversationExplainer.text))
        XCTAssertTrue(server.hasSuffix(PrivateConversationExplainer.serverRecognitionLine))
    }

    /// No plan letters in anything the phone, the lens or the watch shows.
    func testNoWordsNameAPlan() {
        let words = [PrivateConversationExplainer.text, PrivateConversationExplainer.serverRecognitionLine,
                     PrivateConversationLines.badge, PrivateConversationLines.startMenuItem,
                     PrivateConversationLines.endButton, PrivateConversationLines.badgeAccessibilityLabel,
                     PrivateConversationLines.badgeAccessibilityHint,
                     PrivateConversationLines.noManualsWhilePrivate]
        for line in words {
            XCTAssertNil(line.range(of: #"\bPlan [A-Z]{1,2}\b|\bLU\b"#, options: .regularExpression), line)
            XCTAssertFalse(line.isEmpty)
        }
    }

    // MARK: - The page

    func testTheConversationPageDrawsThePrivateConversationNotTheStoredThread() {
        let page = ConversationContinuity.pageContent(
            activeThreadId: "stored", activeThreadMessageCount: 4, isRealtimeSession: false,
            hasLiveUserText: true, hasLiveAssistantText: true, isPrivate: true)
        XCTAssertEqual(page, .privateConversation)
    }

    func testTheStoredThreadComesBackWhenItEnds() {
        let page = ConversationContinuity.pageContent(
            activeThreadId: "stored", activeThreadMessageCount: 4, isRealtimeSession: false,
            hasLiveUserText: false, hasLiveAssistantText: false, isPrivate: false)
        XCTAssertEqual(page, .history(threadId: "stored"))
    }

    func testARealtimeSessionStillDrawsItsLiveTurn() {
        let page = ConversationContinuity.pageContent(
            activeThreadId: nil, activeThreadMessageCount: 0, isRealtimeSession: true,
            hasLiveUserText: true, hasLiveAssistantText: false, isPrivate: true)
        XCTAssertEqual(page, .liveTurn)
    }

    // MARK: - The controller the page reads

    func testTheTranscriptThePageDrawsIsGoneAtTheEnd() {
        let controller = PrivateConversationController()
        XCTAssertNil(controller.begin(entry: .button, conditions: PrivateStartConditions()))
        controller.append(role: "user", content: "a gift for the person next to me")
        controller.append(role: "assistant", content: "How about a book?")
        XCTAssertEqual(controller.transcript.turns.map(\.role), ["user", "assistant"])
        XCTAssertNotNil(controller.handle(.endButton))
        XCTAssertTrue(controller.transcript.isEmpty)
        XCTAssertFalse(controller.isActive)
    }

    func testTheWatchStartIsRecordedAsTheWatchs() {
        let controller = PrivateConversationController()
        XCTAssertNil(controller.begin(entry: .watch, conditions: PrivateStartConditions()))
        XCTAssertEqual(controller.state.entry, .watch)
        XCTAssertEqual(controller.handle(.endOnWatch), .watch)
    }
}
