import XCTest
@testable import OpenGlasses

/// Plan LU P1 — the private conversation's owner: starting and the refusals, every end, the quiet
/// gap, and the model's context coming back. Headless: a fresh `PrivateConversationController`
/// with a test clock, and a fresh `LLMService` for the context.
@MainActor
final class PrivateConversationEndTests: XCTestCase {

    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    override func setUp() {
        super.setUp()
        PrivateConversationGate.setActive(false)
    }

    override func tearDown() {
        PrivateConversationGate.setActive(false)
        super.tearDown()
    }

    private func started(clock: TestClock = TestClock()) -> PrivateConversationController {
        let controller = PrivateConversationController(clock: { clock.now })
        XCTAssertNil(controller.begin(entry: .voicePhrase, conditions: PrivateStartConditions()))
        controller.append(role: "user", content: "a question nobody else should hear")
        controller.append(role: "assistant", content: "an answer nobody else should read")
        return controller
    }

    // MARK: - Every end

    /// The events that end a private conversation, and the reason each gives.
    private let endings: [(PrivateEndEvent, PrivateEndReason)] = [
        (.endPhrase, .endPhrase),
        (.endButton, .endButton),
        (.endOnWatch, .watch),
        (.glassesDisconnected, .glassesDisconnected),
        (.turnStarting(quietFor: PrivateEndPolicy.idleGap), .idle),
        (.idleTimerFired(quietFor: PrivateEndPolicy.idleGap + 1), .idle),
        (.startFresh, .startFresh),
        (.otherConversationOpened, .otherConversationOpened),
        (.conversationReset, .conversationReset),
        (.jobStarted, .jobStarted),
        (.organisationSwitchedOff, .organisationSwitchedOff),
        (.liveStopped(sessionWasPrivate: true), .liveStopped),
        (.appQuit, .appQuit),
    ]

    func testEveryEndDropsTheTranscriptAndALaterTurnIsAnOrdinaryOne() {
        for (event, reason) in endings {
            let controller = started()
            XCTAssertTrue(PrivateConversationGate.isActive, "\(event)")
            XCTAssertEqual(controller.transcript.count, 2, "\(event)")

            XCTAssertEqual(controller.handle(event), reason, "\(event)")

            XCTAssertFalse(controller.isActive, "\(event)")
            XCTAssertTrue(controller.transcript.isEmpty, "the words go with the end: \(event)")
            XCTAssertFalse(PrivateConversationGate.isActive, "\(event)")
            // The next turn is an ordinary one: nothing goes to a private transcript, and every
            // sink is back to keeping what it keeps.
            controller.append(role: "user", content: "an ordinary question")
            XCTAssertTrue(controller.transcript.isEmpty, "\(event)")
            for sink in ConversationSink.allCases {
                XCTAssertEqual(PrivateConversationGate.rule(for: sink), .keep, "\(event): \(sink)")
            }
        }
    }

    func testTheEventsThatDoNotEndItLeaveItOpen() {
        let stays: [PrivateEndEvent] = [
            .appBackgrounded,
            .turnStarting(quietFor: PrivateEndPolicy.idleGap - 1),
            .idleTimerFired(quietFor: 60),
            .liveStopped(sessionWasPrivate: false),
        ]
        for event in stays {
            let controller = started()
            XCTAssertNil(controller.handle(event), "\(event)")
            XCTAssertTrue(controller.isActive, "\(event)")
            XCTAssertEqual(controller.transcript.count, 2, "\(event)")
            controller.end(.endPhrase)
        }
    }

    func testAnEndedConversationCannotBeReopened() {
        let controller = started()
        let first = controller.state.id
        controller.end(.endButton)
        XCTAssertFalse(controller.end(.endButton), "a second end finds nothing open")
        XCTAssertNil(controller.handle(.endPhrase))
        XCTAssertNil(controller.begin(entry: .button, conditions: PrivateStartConditions()))
        XCTAssertNotEqual(controller.state.id, first, "a new start is a new private conversation")
        XCTAssertTrue(controller.transcript.isEmpty, "and starts with nothing of the last one")
        controller.end(.endButton)
    }

    // MARK: - The quiet gap

    func testTheQuietGapIsMeasuredFromTheLastPrivateTurn() {
        let clock = TestClock()
        let controller = started(clock: clock)
        clock.advance(PrivateEndPolicy.idleGap - 60)
        XCTAssertNil(controller.handle(.turnStarting(quietFor: controller.quietFor)))
        controller.append(role: "user", content: "a follow-up")
        clock.advance(PrivateEndPolicy.idleGap - 60)
        XCTAssertNil(controller.handle(.idleTimerFired(quietFor: controller.quietFor)),
                     "the gap restarts at every private turn")
        clock.advance(120)
        XCTAssertEqual(controller.handle(.idleTimerFired(quietFor: controller.quietFor)), .idle)
        XCTAssertEqual(controller.quietFor, 0, "nothing is open, so nothing is quiet")
    }

    // MARK: - Starting, and why not

    func testEachRefusalStartsNothingAndSaysWhy() {
        let cases: [(PrivateStartConditions, PrivateStartRefusal)] = [
            (PrivateStartConditions(jobOpen: true), .jobOpen),
            (PrivateStartConditions(activeThreadBelongsToJob: true), .jobOpen),
            (PrivateStartConditions(organisationPinnedOff: true, allowedInSettings: false), .organisationSwitchedOff),
            (PrivateStartConditions(allowedInSettings: false), .switchedOffInSettings),
            (PrivateStartConditions(liveRunning: true), .liveRunning),
            // A job refuses whatever the settings say (decision 6).
            (PrivateStartConditions(jobOpen: true, organisationPinnedOff: true, liveRunning: true), .jobOpen),
        ]
        for (conditions, refusal) in cases {
            let controller = PrivateConversationController()
            XCTAssertEqual(controller.begin(entry: .voicePhrase, conditions: conditions), refusal)
            XCTAssertFalse(controller.isActive)
            XCTAssertFalse(PrivateConversationGate.isActive)
        }
        XCTAssertEqual(PrivateStartRefusal.jobOpen.reason,
                       "Not during a job: its record has to be complete. End the job first.")
        XCTAssertEqual(PrivateStartRefusal.organisationSwitchedOff.reason,
                       "Your organisation has switched private conversations off.")
        for refusal in PrivateStartRefusal.allCases {
            XCTAssertFalse(refusal.reason.isEmpty, refusal.rawValue)
        }
    }

    func testStartingWhenAlreadyPrivateChangesNothing() {
        let controller = started()
        let id = controller.state.id
        XCTAssertNil(controller.begin(entry: .button, conditions: PrivateStartConditions()))
        XCTAssertEqual(controller.state.id, id)
        XCTAssertEqual(controller.transcript.count, 2)
        controller.end(.endButton)
    }

    // MARK: - What is said

    func testOnlyAnEndTheWearerHearsIsSaid() {
        XCTAssertTrue(PrivateConversationLines.announcesEnd(.endPhrase))
        XCTAssertTrue(PrivateConversationLines.announcesEnd(.turnStarting(quietFor: 0)))
        XCTAssertTrue(PrivateConversationLines.announcesEnd(.startFresh))
        XCTAssertFalse(PrivateConversationLines.announcesEnd(.glassesDisconnected))
        XCTAssertFalse(PrivateConversationLines.announcesEnd(.appQuit))
        XCTAssertFalse(PrivateConversationLines.announcesEnd(.idleTimerFired(quietFor: 0)))
        XCTAssertFalse(PrivateConversationLines.announcesEnd(.conversationReset),
                       "a reset says its own line")
        XCTAssertEqual(PrivateConversationLines.startedWithQuestion, "Private. I won't keep any of this.")
        XCTAssertEqual(PrivateConversationLines.startedAlone, "Private. Go ahead.")
        XCTAssertEqual(PrivateConversationLines.ended, "Private conversation ended.")
    }

    // MARK: - The model's context

    func testTheStoredConversationsContextComesBackAsItWas() {
        let llm = LLMService()
        llm.recordExternalExchange(user: "what's on today?", assistant: "Two meetings.")
        let stored = llm.conversationHistoryForTesting().map { "\($0.role):\($0.content)" }

        llm.beginPrivateHistory(PrivateTranscript().replayMessages())
        XCTAssertTrue(llm.conversationHistoryForTesting().isEmpty, "a private conversation starts clean")
        XCTAssertTrue(llm.holdsPrivateHistory)
        llm.recordExternalExchange(user: "a private question", assistant: "a private answer")
        XCTAssertEqual(llm.conversationHistoryForTesting().count, 2, "follow-ups see the private turns")

        llm.endPrivateHistory()
        XCTAssertFalse(llm.holdsPrivateHistory)
        XCTAssertEqual(llm.conversationHistoryForTesting().map { "\($0.role):\($0.content)" }, stored)
        llm.endPrivateHistory()   // nothing to restore: a no-op
        XCTAssertEqual(llm.conversationHistoryForTesting().count, stored.count)
    }

    // MARK: - Recognition (decision 4)

    func testAPrivateQuestionStaysOnThePhoneWhereTheLocaleCan() {
        XCTAssertTrue(PrivateRecognitionPolicy.requiresOnDevice(isPrivate: true, localeSupportsOnDevice: true))
        XCTAssertFalse(PrivateRecognitionPolicy.requiresOnDevice(isPrivate: true, localeSupportsOnDevice: false),
                       "where it can't, server recognition is used")
        XCTAssertFalse(PrivateRecognitionPolicy.requiresOnDevice(isPrivate: false, localeSupportsOnDevice: true))
        XCTAssertFalse(PrivateRecognitionPolicy.allowsCloudVendor(isPrivate: true))
        XCTAssertTrue(PrivateRecognitionPolicy.allowsCloudVendor(isPrivate: false))
    }
}
