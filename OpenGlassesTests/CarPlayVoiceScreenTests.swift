import XCTest
@testable import OpenGlasses

/// The CarPlay voice screen: voice first on connect without opening anything, the state shown
/// follows the conversation, the buttons each state carries, no wedge after an end, Stop is not
/// End, every end releases the audio, and the car screen never goes past depth three.
final class CarPlayVoiceScreenTests: XCTestCase {

    private typealias Screen = CarPlayVoiceScreen
    private typealias Conversation = CarPlayVoiceScreen.Conversation
    private typealias VoiceState = CarPlayVoiceScreen.VoiceState

    private func conversation(open: Bool = true, listening: Bool = false,
                              processing: Bool = false, speaking: Bool = false) -> Conversation {
        Conversation(inConversation: open, isListening: listening,
                     isProcessing: processing, isSpeaking: speaking)
    }

    private var listening: Conversation { conversation(listening: true) }
    private var thinking: Conversation { conversation(processing: true) }
    private var speaking: Conversation { conversation(speaking: true) }
    private let over = Conversation.idle

    /// The iOS 26.4+ screen, connected and on ready.
    private func readyScreen() -> Screen {
        var screen = Screen(hasButtons: true)
        XCTAssertTrue(screen.connected())
        return screen
    }

    /// A screen that has been started and seen its conversation begin.
    private func runningScreen(hasButtons: Bool = true) -> Screen {
        var screen = Screen(hasButtons: hasButtons)
        if hasButtons {
            _ = screen.connected()
            XCTAssertEqual(screen.start(over), .startConversation)
        } else {
            XCTAssertEqual(screen.start(over), .presentAndStartConversation)
        }
        XCTAssertEqual(screen.startFinished(listening), .none)
        return screen
    }

    // MARK: - States and buttons

    func testStateIdentifiersAreTheTemplateStateIdentifiers() {
        XCTAssertEqual(VoiceState.allCases.map(\.rawValue), ["ready", "listening", "processing", "speaking"])
        for state in VoiceState.allCases {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.symbol.isEmpty)
        }
        for button in CarPlayVoiceScreen.Button.allCases {
            XCTAssertFalse(button.title.isEmpty)
            XCTAssertFalse(button.symbol.isEmpty)
        }
    }

    func testTheButtonsEachStateCarries() {
        XCTAssertEqual(VoiceState.ready.buttons, [.talk])
        XCTAssertEqual(VoiceState.listening.buttons, [.end])
        XCTAssertEqual(VoiceState.processing.buttons, [.end])
        XCTAssertEqual(VoiceState.speaking.buttons, [.stop, .end])
        for state in VoiceState.allCases {
            XCTAssertLessThanOrEqual(state.buttons.count, Screen.maximumButtons, "\(state)")
        }
    }

    func testTheTemplateOpensOnReadyWithButtonsAndOnListeningWithout() {
        XCTAssertEqual(Screen.states(hasButtons: true).first, .ready)
        XCTAssertEqual(Screen.states(hasButtons: true), VoiceState.allCases)
        XCTAssertEqual(Screen.states(hasButtons: false), [.listening, .processing, .speaking])
        // At most five states, CarPlay's limit.
        XCTAssertLessThanOrEqual(Screen.states(hasButtons: true).count, 5)
    }

    func testStateFollowsTheConversation() {
        XCTAssertEqual(VoiceState(listening), .listening)
        XCTAssertEqual(VoiceState(thinking), .processing)
        XCTAssertEqual(VoiceState(speaking), .speaking)
        // Between turns — open, nothing in flight — is listening.
        XCTAssertEqual(VoiceState(conversation()), .listening)
        // What the driver hears wins.
        XCTAssertEqual(VoiceState(conversation(processing: true, speaking: true)), .speaking)
    }

    func testOverNeedsAllFourFlagsClear() {
        XCTAssertTrue(over.isOver)
        XCTAssertFalse(conversation().isOver)
        // Push-to-talk closes the conversation before the reply: still not over.
        XCTAssertFalse(conversation(open: false, processing: true).isOver)
        XCTAssertFalse(conversation(open: false, speaking: true).isOver)
        XCTAssertFalse(conversation(open: false, listening: true).isOver)
    }

    // MARK: - Voice first (connect)

    func testConnectPresentsTheReadyScreenAndOpensNothing() {
        var screen = Screen(hasButtons: true)
        XCTAssertTrue(screen.connected())
        XCTAssertEqual(screen.screen, .ready)
        XCTAssertEqual(screen.shownState, .ready)
        // Ready is idle: the car does not listen or talk until Talk.
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertFalse(screen.releaseOwed)
        // Connecting again while up does not present twice.
        XCTAssertFalse(screen.connected())
    }

    func testWithoutButtonsTheCarOpensOnTheTabsAsBefore() {
        var screen = Screen(hasButtons: false)
        XCTAssertFalse(screen.connected())
        XCTAssertFalse(screen.isPresented)
    }

    // MARK: - Start

    func testTalkOnReadyStartsAConversationWithoutPresentingAgain() {
        var screen = readyScreen()
        XCTAssertEqual(screen.start(over), .startConversation)
        XCTAssertEqual(screen.screen, .starting)
        XCTAssertEqual(screen.shownState, .listening)
    }

    func testStartWithTheScreenGonePresentsAndStarts() {
        var screen = Screen(hasButtons: false)
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
        XCTAssertTrue(screen.isPresented)
    }

    func testStartWhileTalkingDoesNothing() {
        var screen = runningScreen()
        XCTAssertEqual(screen.start(over), .nothing)
        XCTAssertEqual(screen.start(speaking), .nothing)
    }

    func testStartOverARunningConversationShowsItWithoutStartingAnother() {
        var hidden = Screen(hasButtons: true)
        XCTAssertEqual(hidden.start(speaking), .presentOverRunningConversation(.speaking))
        XCTAssertEqual(hidden.screen, .showing(.speaking))

        var ready = readyScreen()
        XCTAssertEqual(ready.start(thinking), .show(.processing))
    }

    func testTheReadyScreenFollowsAConversationItDidNotStart() {
        // The wake word in the car, or the opt-in brief on connect.
        var screen = readyScreen()
        XCTAssertEqual(screen.observe(conversation(open: false, speaking: true)), .show(.speaking))
        XCTAssertEqual(screen.observe(over), .showReady)
    }

    func testTheGapBeforeTheConversationOpensIsNotAnEnd() {
        var screen = readyScreen()
        _ = screen.start(over)
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertEqual(screen.screen, .starting)
        // The conversation opens: listening is what the template already shows.
        XCTAssertEqual(screen.observe(listening), .none)
        XCTAssertEqual(screen.screen, .showing(.listening))
    }

    func testAStartThatOpensStraightIntoThinkingSaysSo() {
        var screen = readyScreen()
        _ = screen.start(over)
        XCTAssertEqual(screen.observe(thinking), .show(.processing))
    }

    func testAStartThatNeverOpenedAConversationRests() {
        var withButtons = readyScreen()
        _ = withButtons.start(over)
        XCTAssertEqual(withButtons.startFinished(over), .showReady)
        XCTAssertEqual(withButtons.screen, .ready)
        XCTAssertTrue(withButtons.releaseOwed)
        XCTAssertEqual(withButtons.start(over), .startConversation)

        var without = Screen(hasButtons: false)
        _ = without.start(over)
        XCTAssertEqual(without.startFinished(over), .dismiss)
        XCTAssertFalse(without.isPresented)
        XCTAssertEqual(without.start(over), .presentAndStartConversation)
    }

    func testStartFinishedAfterTheConversationWasAlreadySeenIsAnObservation() {
        var screen = readyScreen()
        _ = screen.start(over)
        _ = screen.observe(listening)
        XCTAssertEqual(screen.startFinished(thinking), .show(.processing))
    }

    // MARK: - Following the conversation

    func testAFullTurnWalksListeningThinkingSpeaking() {
        var screen = runningScreen()
        XCTAssertEqual(screen.observe(thinking), .show(.processing))
        XCTAssertEqual(screen.observe(thinking), .none)
        XCTAssertEqual(screen.observe(speaking), .show(.speaking))
        XCTAssertEqual(screen.observe(listening), .show(.listening))
        XCTAssertEqual(screen.observe(conversation()), .none)
    }

    func testHiddenScreenIgnoresTheConversation() {
        var screen = Screen(hasButtons: true)
        XCTAssertEqual(screen.observe(speaking), .none)
        XCTAssertEqual(screen.observe(over), .none)
        XCTAssertFalse(screen.isPresented)
    }

    // MARK: - Not wedging

    func testAConversationEndingByItselfGoesBackToReady() {
        var screen = runningScreen()
        _ = screen.observe(speaking)
        XCTAssertEqual(screen.observe(over), .showReady)
        XCTAssertEqual(screen.screen, .ready)
        XCTAssertTrue(screen.releaseOwed)
        XCTAssertEqual(screen.observe(over), .none)
        // The wedge: Talk after the conversation ended must start one.
        XCTAssertEqual(screen.start(over), .startConversation)
    }

    func testWithoutButtonsAnEndTakesTheScreenDown() {
        var screen = runningScreen(hasButtons: false)
        XCTAssertEqual(screen.observe(over), .dismiss)
        XCTAssertFalse(screen.isPresented)
        XCTAssertEqual(screen.start(over), .presentAndStartConversation)
    }

    func testPushToTalkReplyAfterTheConversationClosedKeepsTheScreen() {
        var screen = runningScreen()
        XCTAssertEqual(screen.observe(conversation(open: false, processing: true)), .show(.processing))
        XCTAssertEqual(screen.observe(conversation(open: false, speaking: true)), .show(.speaking))
        XCTAssertEqual(screen.observe(over), .showReady)
    }

    func testTheSystemTakingTheTemplateDownIsForgotten() {
        var screen = runningScreen()
        screen.templateDisappeared()
        XCTAssertFalse(screen.isPresented)
        // The conversation it was showing carries on; Start puts the screen back over it.
        XCTAssertEqual(screen.start(listening), .presentOverRunningConversation(.listening))
    }

    func testTheSystemTakingTheTemplateDownWhileStarting() {
        var screen = readyScreen()
        _ = screen.start(over)
        screen.templateDisappeared()
        XCTAssertEqual(screen.startFinished(listening), .none)
        XCTAssertFalse(screen.isPresented)
    }

    // MARK: - The audio session

    func testANaturalEndReleasesOnceTheAppHasFinishedEnding() {
        var screen = runningScreen()
        XCTAssertEqual(screen.observe(over), .showReady)
        XCTAssertEqual(screen.appFinishedEnding(over), .release(screen: .none))
        XCTAssertFalse(screen.releaseOwed)
        // Nothing left to fall back on.
        XCTAssertFalse(screen.releaseFallbackDue(over))
    }

    func testTheEndPathFinishingBeforeTheObservationStillRests() {
        var screen = runningScreen()
        XCTAssertEqual(screen.appFinishedEnding(over), .release(screen: .showReady))
        XCTAssertEqual(screen.screen, .ready)
        XCTAssertEqual(screen.observe(over), .none)
    }

    func testNoReleaseWhileTheConversationIsStillGoing() {
        var screen = runningScreen()
        XCTAssertEqual(screen.appFinishedEnding(conversation(open: false, speaking: true)), .none)
        var starting = readyScreen()
        _ = starting.start(over)
        XCTAssertEqual(starting.appFinishedEnding(over), .none)
    }

    func testTheReadyScreenReleasesAfterAnEndItDidNotSee() {
        var screen = readyScreen()
        XCTAssertEqual(screen.appFinishedEnding(over), .release(screen: .none))
    }

    func testTheFallbackReleasesAnEndWithNoEndPath() {
        // A brief read out on the ready screen ends with no `returnToWakeWord` behind it.
        var screen = readyScreen()
        _ = screen.observe(conversation(open: false, speaking: true))
        XCTAssertEqual(screen.observe(over), .showReady)
        XCTAssertTrue(screen.releaseFallbackDue(over))
        XCTAssertFalse(screen.releaseFallbackDue(over))
    }

    func testTheFallbackWaitsForANewConversation() {
        var screen = runningScreen()
        _ = screen.observe(over)
        _ = screen.start(over)
        XCTAssertFalse(screen.releaseFallbackDue(over))
        XCTAssertFalse(screen.releaseFallbackDue(listening))
    }

    // MARK: - Stop is not End

    func testStopCutsTheReplyOffAndKeepsTheConversation() {
        var screen = runningScreen()
        _ = screen.observe(speaking)
        XCTAssertEqual(screen.stop(speaking), .interruptAndListen)
        // Stop never moves the screen.
        XCTAssertTrue(screen.isPresented)
        XCTAssertEqual(screen.observe(listening), .show(.listening))
    }

    func testStopOutsideAConversationOnlySilencesTheReadOut() {
        let screen = readyScreen()
        XCTAssertEqual(screen.stop(conversation(open: false, speaking: true)), .stopSpeaking)
    }

    func testStopWithNothingBeingSaidDoesNothing() {
        let screen = runningScreen()
        XCTAssertEqual(screen.stop(listening), .nothing)
        XCTAssertEqual(screen.stop(thinking), .nothing)
        XCTAssertEqual(screen.stop(over), .nothing)
    }

    func testEndHangsUpGoesBackToReadyAndOwesARelease() {
        var screen = runningScreen()
        XCTAssertEqual(screen.end(speaking), .init(hangUp: true, screen: .showReady))
        XCTAssertEqual(screen.screen, .ready)
        XCTAssertTrue(screen.releaseOwed)
        XCTAssertEqual(screen.appFinishedEnding(over), .release(screen: .none))
        XCTAssertEqual(screen.start(over), .startConversation)
    }

    func testEndWithoutButtonsTakesTheScreenDown() {
        var screen = runningScreen(hasButtons: false)
        XCTAssertEqual(screen.end(listening), .init(hangUp: true, screen: .dismiss))
        XCTAssertFalse(screen.isPresented)
    }

    func testEndWhileStartingHangsUp() {
        var screen = readyScreen()
        _ = screen.start(over)
        XCTAssertEqual(screen.end(over), .init(hangUp: true, screen: .showReady))
        XCTAssertEqual(screen.startFinished(listening), .show(.listening))
    }

    func testEndWithTheScreenGoneStillHangsUpARunningConversation() {
        var screen = runningScreen()
        screen.templateDisappeared()
        XCTAssertEqual(screen.end(speaking), .init(hangUp: true, screen: .none))
        XCTAssertTrue(screen.releaseOwed)
    }

    func testEndWithNothingRunningDoesNothing() {
        var hidden = Screen(hasButtons: true)
        XCTAssertEqual(hidden.end(over), .nothing)
        var ready = readyScreen()
        XCTAssertEqual(ready.end(over), .nothing)
        XCTAssertFalse(ready.releaseOwed)
    }

    func testCarDisconnectEndsOnlyTheConversationItWasShowing() {
        var shown = runningScreen()
        XCTAssertEqual(shown.carDisconnected(),
                       .init(hangUp: true, screen: .none, restorePhoneAudio: true))
        XCTAssertFalse(shown.isPresented)
        // The phone's own end path hands the audio back; no CarPlay release is left owed.
        XCTAssertFalse(shown.releaseFallbackDue(over))

        var ready = readyScreen()
        XCTAssertEqual(ready.carDisconnected(),
                       .init(hangUp: false, screen: .none, restorePhoneAudio: true))
        XCTAssertFalse(ready.isPresented)

        var notShown = Screen(hasButtons: true)
        XCTAssertFalse(notShown.carDisconnected().hangUp)
    }

    /// CarPlay's audio mode ends with the car, every time — whatever the screen was doing.
    func testCarDisconnectAlwaysRestoresThePhonesAudio() {
        var ended = runningScreen()
        _ = ended.observe(over)
        XCTAssertTrue(ended.releaseOwed)
        XCTAssertTrue(ended.carDisconnected().restorePhoneAudio)
        XCTAssertFalse(ended.releaseOwed)

        for hasButtons in [true, false] {
            var screen = Screen(hasButtons: hasButtons)
            XCTAssertTrue(screen.carDisconnected().restorePhoneAudio)
        }
        // Nothing else ever leaves CarPlay's audio mode.
        var screen = runningScreen()
        XCTAssertFalse(screen.end(speaking).restorePhoneAudio)
    }

    // MARK: - Template depth

    func testEveryPathStaysWithinDepthThree() {
        XCTAssertEqual(Screen.maximumDepth, 3)
        // A tab's list: tab bar + list.
        XCTAssertEqual(Screen.depth(pushed: 0, voicePresented: false), 2)
        // The voice screen over a tab (connect, Voice, Conversations, Playbooks, Jobs rows).
        XCTAssertEqual(Screen.depth(pushed: 0, voicePresented: true), 3)
        // Jobs → a job ahead → its Brief / Directions actions.
        XCTAssertEqual(Screen.depth(pushed: 1, voicePresented: false), 3)
        // The voice screen is never presented over that page: the stack goes back to the tab.
        XCTAssertFalse(Screen.mustPopToRootBeforePresenting(pushed: 0))
        XCTAssertTrue(Screen.mustPopToRootBeforePresenting(pushed: 1))
    }
}
