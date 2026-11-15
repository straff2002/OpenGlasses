import XCTest
@testable import OpenGlasses

/// Plan LU P0 §8 — what ends a private conversation, and what doesn't.
final class PrivateEndPolicyTests: XCTestCase {

    private let active = PrivateConversationState.active(id: UUID(), startedAt: Date(), entry: .voicePhrase)

    func testEveryEndingEventEndsWithItsReason() {
        let cases: [(PrivateEndEvent, PrivateEndReason)] = [
            (.endPhrase, .endPhrase),
            (.endButton, .endButton),
            (.endOnWatch, .watch),
            (.glassesDisconnected, .glassesDisconnected),
            (.turnStarting(quietFor: 30 * 60), .idle),
            (.idleTimerFired(quietFor: 31 * 60), .idle),
            (.startFresh, .startFresh),
            (.otherConversationOpened, .otherConversationOpened),
            (.conversationReset, .conversationReset),
            (.jobStarted, .jobStarted),
            (.organisationSwitchedOff, .organisationSwitchedOff),
            (.liveStopped(sessionWasPrivate: true), .liveStopped),
            (.appQuit, .appQuit),
        ]
        for (event, reason) in cases {
            XCTAssertEqual(PrivateEndPolicy.decide(active, event), .end(reason), "\(event)")
        }
        // Every reason is reachable from some event.
        XCTAssertEqual(Set(cases.map { $0.1 }), Set(PrivateEndReason.allCases))
    }

    /// The wearer may be using the glasses with the phone locked.
    func testBackgroundingStays() {
        XCTAssertEqual(PrivateEndPolicy.decide(active, .appBackgrounded), .stay)
    }

    func testATurnInsideTheQuietGapStays() {
        XCTAssertEqual(PrivateEndPolicy.decide(active, .turnStarting(quietFor: 0)), .stay)
        XCTAssertEqual(PrivateEndPolicy.decide(active, .turnStarting(quietFor: 29 * 60 + 59)), .stay)
        XCTAssertEqual(PrivateEndPolicy.decide(active, .idleTimerFired(quietFor: 10 * 60)), .stay)
    }

    func testAnOrdinaryLiveSessionStoppingStays() {
        XCTAssertEqual(PrivateEndPolicy.decide(active, .liveStopped(sessionWasPrivate: false)), .stay)
    }

    /// The gap is the one ordinary conversations already use, not a second constant.
    func testTheQuietGapIsTheConversationIdleGap() {
        XCTAssertEqual(PrivateEndPolicy.idleGap, JobThreadPolicy.conversationIdleGap)
        XCTAssertEqual(PrivateEndPolicy.idleGap, 30 * 60)
    }

    /// With no private conversation open there is nothing to end.
    func testNothingEndsWhenInactive() {
        let events: [PrivateEndEvent] = [
            .endPhrase, .endButton, .endOnWatch, .glassesDisconnected, .turnStarting(quietFor: 3600),
            .idleTimerFired(quietFor: 3600), .startFresh, .otherConversationOpened, .conversationReset,
            .jobStarted, .organisationSwitchedOff, .liveStopped(sessionWasPrivate: true),
            .appBackgrounded, .appQuit,
        ]
        for event in events {
            XCTAssertEqual(PrivateEndPolicy.decide(.inactive, event), .stay, "\(event)")
        }
    }

    // MARK: - The state and the transcript

    func testTheStateCarriesItsEntry() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let state = PrivateConversationState.active(id: id, startedAt: start, entry: .watch)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.id, id)
        XCTAssertEqual(state.startedAt, start)
        XCTAssertEqual(state.entry, .watch)
        XCTAssertFalse(PrivateConversationState.inactive.isActive)
        XCTAssertNil(PrivateConversationState.inactive.id)
        XCTAssertNil(PrivateConversationState.inactive.entry)
    }

    func testTheTranscriptReplaysLikeAStoredThreadAndClears() {
        var transcript = PrivateTranscript()
        XCTAssertNil(transcript.lastTurnAt)
        let later = Date(timeIntervalSince1970: 2_000)
        transcript.append(role: "user", content: "a question", at: Date(timeIntervalSince1970: 1_000))
        transcript.append(role: "assistant", content: "an answer", at: later)

        let replay = transcript.replayMessages()
        XCTAssertEqual(replay.map { $0.role }, ["user", "assistant"])
        XCTAssertEqual(replay.map { $0.content }, ["a question", "an answer"])
        XCTAssertEqual(transcript.lastTurnAt, later)
        XCTAssertEqual(transcript.count, 2)

        transcript.clear()
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertTrue(transcript.replayMessages().isEmpty)
    }
}
