import XCTest
@testable import OpenGlasses

/// The CarPlay voice screen: the state it shows follows the conversation, it goes away when the
/// conversation ends by itself or the system takes it down (so Start Listening never silently does
/// nothing), and Stop is not End.
final class CarPlayVoiceScreenTests: XCTestCase {

    private typealias Screen = CarPlayVoiceScreen
    private typealias Conversation = CarPlayVoiceScreen.Conversation

    private func conversation(open: Bool = true, listening: Bool = false,
                              processing: Bool = false, speaking: Bool = false) -> Conversation {
        Conversation(inConversation: open, isListening: listening,
                     isProcessing: processing, isSpeaking: speaking)
    }

    private var listening: Conversation { conversation(listening: true) }
    private var thinking: Conversation { conversation(processing: true) }
    private var speaking: Conversation { conversation(speaking: true) }
    private let over = Conversation.idle

    /// A screen that has been started and seen its conversation begin.
    private func runningScreen() -> Screen {
        var screen = Screen()
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
        XCTAssertEqual(screen.startFinished(listening), .none)
        return screen
    }

    // MARK: - Phase

    func testPhaseIdentifiersAreTheTemplateStateIdentifiers() {
        XCTAssertEqual(Screen.Phase.allCases.map(\.rawValue), ["listening", "processing", "speaking"])
        for phase in Screen.Phase.allCases {
            XCTAssertFalse(phase.title.isEmpty)
            XCTAssertFalse(phase.symbol.isEmpty)
        }
    }

    func testPhaseFollowsTheConversation() {
        XCTAssertEqual(Screen.Phase(listening), .listening)
        XCTAssertEqual(Screen.Phase(thinking), .processing)
        XCTAssertEqual(Screen.Phase(speaking), .speaking)
        // Between turns — open, nothing in flight — is listening.
        XCTAssertEqual(Screen.Phase(conversation()), .listening)
        // What the driver hears wins.
        XCTAssertEqual(Screen.Phase(conversation(processing: true, speaking: true)), .speaking)
    }

    func testOverNeedsAllFourFlagsClear() {
        XCTAssertTrue(over.isOver)
        XCTAssertFalse(conversation().isOver)
        // Push-to-talk closes the conversation before the reply: still not over.
        XCTAssertFalse(conversation(open: false, processing: true).isOver)
        XCTAssertFalse(conversation(open: false, speaking: true).isOver)
        XCTAssertFalse(conversation(open: false, listening: true).isOver)
    }

    // MARK: - Start

    func testStartPresentsAndStartsAConversationWhenNoneIsRunning() {
        var screen = Screen()
        XCTAssertFalse(screen.isPresented)
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
        XCTAssertTrue(screen.isPresented)
        XCTAssertEqual(screen.screen, .starting)
    }

    func testStartWhileUpDoesNothing() {
        var screen = runningScreen()
        XCTAssertEqual(screen.start(over), .nothing)
        XCTAssertEqual(screen.start(speaking), .nothing)
    }

    func testStartOverARunningConversationShowsItWithoutStartingAnother() {
        var screen = Screen()
        XCTAssertEqual(screen.start(speaking), .presentOverRunningConversation(.speaking))
        XCTAssertEqual(screen.screen, .showing(.speaking))
    }

    func testTheGapBeforeTheConversationOpensIsNotAnEnd() {
        var screen = Screen()
        _ = screen.start(over)
        // Published changes before `handleWakeWordDetected` opens the conversation.
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertEqual(screen.screen, .starting)
        // The conversation opens: listening is what the template already shows.
        XCTAssertEqual(screen.observe(listening), .none)
        XCTAssertEqual(screen.screen, .showing(.listening))
    }

    func testAStartThatOpensStraightIntoThinkingSaysSo() {
        var screen = Screen()
        _ = screen.start(over)
        XCTAssertEqual(screen.observe(thinking), .show(.processing))
    }

    func testAStartThatNeverOpenedAConversationTakesTheScreenDown() {
        var screen = Screen()
        _ = screen.start(over)
        XCTAssertEqual(screen.startFinished(over), .dismiss)
        XCTAssertFalse(screen.isPresented)
        // And the next tap starts again.
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
    }

    func testStartFinishedAfterTheConversationWasAlreadySeenIsAnObservation() {
        var screen = Screen()
        _ = screen.start(over)
        _ = screen.observe(listening)
        XCTAssertEqual(screen.startFinished(thinking), .show(.processing))
    }

    // MARK: - Following the conversation (bug 1)

    func testAFullTurnWalksListeningThinkingSpeaking() {
        var screen = runningScreen()
        XCTAssertEqual(screen.observe(thinking), .show(.processing))
        XCTAssertEqual(screen.observe(thinking), .none)
        XCTAssertEqual(screen.observe(speaking), .show(.speaking))
        XCTAssertEqual(screen.observe(listening), .show(.listening))
        XCTAssertEqual(screen.observe(conversation()), .none)
    }

    func testHiddenScreenIgnoresTheConversation() {
        var screen = Screen()
        XCTAssertEqual(screen.observe(speaking), .none)
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertFalse(screen.isPresented)
    }

    // MARK: - Not wedging (bug 2)

    func testAConversationEndingByItselfTakesTheScreenDown() {
        var screen = runningScreen()
        _ = screen.observe(speaking)
        XCTAssertEqual(screen.observe(over), .dismiss)
        XCTAssertFalse(screen.isPresented)
        XCTAssertEqual(screen.observe(over), .none)
        // The wedge: Start Listening after the conversation ended must start one.
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
    }

    func testPushToTalkReplyAfterTheConversationClosedKeepsTheScreen() {
        var screen = runningScreen()
        XCTAssertEqual(screen.observe(conversation(open: false, processing: true)), .show(.processing))
        XCTAssertEqual(screen.observe(conversation(open: false, speaking: true)), .show(.speaking))
        XCTAssertEqual(screen.observe(over), .dismiss)
    }

    func testTheSystemTakingTheTemplateDownIsForgotten() {
        var screen = runningScreen()
        screen.templateDisappeared()
        XCTAssertFalse(screen.isPresented)
        // The conversation it was showing carries on; Start puts the screen back over it.
        XCTAssertEqual(screen.start(listening), .presentOverRunningConversation(.listening))
    }

    func testTheSystemTakingTheTemplateDownWhileStarting() {
        var screen = Screen()
        _ = screen.start(over)
        screen.templateDisappeared()
        // The start's own completion no longer drives a screen that is gone.
        XCTAssertEqual(screen.startFinished(listening), .none)
        XCTAssertFalse(screen.isPresented)
    }

    // MARK: - Stop is not End (bug 3)

    func testStopCutsTheReplyOffAndKeepsTheConversation() {
        var screen = runningScreen()
        XCTAssertEqual(screen.stop(speaking), .interruptAndListen)
        // Stop never takes the screen down.
        XCTAssertTrue(screen.isPresented)
        XCTAssertEqual(screen.observe(listening), .none)
    }

    func testStopOutsideAConversationOnlySilencesTheReadOut() {
        let screen = Screen()
        XCTAssertEqual(screen.stop(conversation(open: false, speaking: true)), .stopSpeaking)
    }

    func testStopWithNothingBeingSaidDoesNothing() {
        let screen = runningScreen()
        XCTAssertEqual(screen.stop(listening), .nothing)
        XCTAssertEqual(screen.stop(thinking), .nothing)
        XCTAssertEqual(screen.stop(over), .nothing)
    }

    func testEndHangsUpAndTakesTheScreenDown() {
        var screen = runningScreen()
        XCTAssertEqual(screen.end(speaking), .init(hangUp: true, dismiss: true))
        XCTAssertFalse(screen.isPresented)
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
    }

    func testEndWhileStartingHangsUp() {
        var screen = Screen()
        _ = screen.start(over)
        XCTAssertEqual(screen.end(over), .init(hangUp: true, dismiss: true))
        XCTAssertEqual(screen.startFinished(listening), .none)
    }

    func testEndWithTheScreenGoneStillHangsUpARunningConversation() {
        var screen = runningScreen()
        screen.templateDisappeared()
        XCTAssertEqual(screen.end(speaking), .init(hangUp: true, dismiss: false))
    }

    func testEndWithNothingRunningDoesNothing() {
        var screen = Screen()
        XCTAssertEqual(screen.end(over), .nothing)
    }

    func testCarDisconnectEndsOnlyTheConversationItWasShowing() {
        var shown = runningScreen()
        XCTAssertEqual(shown.carDisconnected(), .init(hangUp: true, dismiss: true))
        XCTAssertFalse(shown.isPresented)

        var notShown = Screen()
        XCTAssertEqual(notShown.carDisconnected(), .nothing)
    }
}
