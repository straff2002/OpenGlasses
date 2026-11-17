import XCTest
@testable import OpenGlasses

/// What "Hey Meta, open Avenkin" does, by what the app is doing (Plan JV P1). Headless and compiled
/// in every build: the decision touches no experimental API.
final class VoiceInvocationResolverTests: XCTestCase {

    private func context(_ activity: TempleContext.Activity, micMuted: Bool = false, liveMicMuted: Bool = false,
                         otherParty: Bool = false) -> VoiceInvocationContext {
        VoiceInvocationContext(
            temple: TempleContext(activity: activity, micMuted: micMuted, liveMicMuted: liveMicMuted),
            otherPartyOnLine: otherParty)
    }

    func testTheActivityTable() {
        let table: [(TempleContext.Activity, VoiceInvocationOutcome)] = [
            (.standby, .run(.startListening)),
            (.speaking, .run(.interruptAndListen)),
            (.listening, .alreadyListening),
            (.liveSession, .alreadyListening),
            (.thinking, .refuse(.busy)),
            (.busy, .refuse(.busy)),
        ]
        for (activity, expected) in table {
            XCTAssertEqual(VoiceInvocationResolver.resolve(context(activity)), expected, "\(activity)")
        }
    }

    /// The same meaning as "start talking" on the temple taps, wherever that is taken.
    func testItAgreesWithTheTempleTapsStartTalking() {
        for activity in [TempleContext.Activity.standby, .speaking] {
            let tap = TempleActionResolver.resolve(action: .startTalking, context: TempleContext(activity: activity))
            let voice = VoiceInvocationResolver.resolve(context(activity))
            switch (tap, voice) {
            case (.run(.startListening), .run(.startListening)), (.run(.interruptAndListen), .run(.interruptAndListen)):
                break
            default:
                XCTFail("\(activity): temple \(tap), voice \(voice)")
            }
        }
    }

    func testAMutedMicIsAFailureWithAReason() {
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.standby, micMuted: true)), .refuse(.micMuted))
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.speaking, micMuted: true)), .refuse(.micMuted))
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.liveSession, liveMicMuted: true)), .refuse(.micMuted))
        // A live session's own mute is what counts in a live session, and the wake word's elsewhere.
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.liveSession, micMuted: true)), .alreadyListening)
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.standby, liveMicMuted: true)), .run(.startListening))
    }

    func testACallWithAnotherPersonIsLeftAlone() {
        for activity in [TempleContext.Activity.standby, .listening, .speaking, .liveSession, .busy] {
            XCTAssertEqual(VoiceInvocationResolver.resolve(context(activity, otherParty: true)), .refuse(.otherParty),
                           "\(activity)")
        }
    }

    func testTheSwitchOffIsAFailure() {
        XCTAssertEqual(VoiceInvocationResolver.resolve(context(.standby), enabled: false), .refuse(.switchedOff))
    }

    func testEveryOutcomeHasAnAnswer() {
        XCTAssertEqual(VoiceInvocationResolver.answer(for: .run(.startListening), started: true), .success)
        XCTAssertEqual(VoiceInvocationResolver.answer(for: .run(.interruptAndListen), started: false),
                       .failure(.didNotStart))
        XCTAssertEqual(VoiceInvocationResolver.answer(for: .alreadyListening, started: false), .success)
        for refusal in VoiceInvocationRefusal.allCases {
            let answer = VoiceInvocationResolver.answer(for: .refuse(refusal), started: true)
            XCTAssertFalse(answer.success)
            XCTAssertEqual(answer.refusal, refusal)
            XCTAssertEqual(answer.actionOutput, refusal.actionOutput)
        }
        XCTAssertNil(VoiceInvocationAnswer.success.actionOutput)
    }

    /// The assistant reads it aloud: one short sentence.
    func testEveryFailureSaysAtMostOneShortSentence() {
        for refusal in VoiceInvocationRefusal.allCases {
            let output = refusal.actionOutput
            XCTAssertFalse(output.isEmpty, refusal.rawValue)
            XCTAssertLessThanOrEqual(output.count, 60, refusal.rawValue)
            XCTAssertEqual(output.filter { ".!?".contains($0) }.count, 1, refusal.rawValue)
            XCTAssertTrue(output.hasSuffix("."), refusal.rawValue)
        }
    }

    func testListeningAfterAnAction() {
        XCTAssertTrue(VoiceInvocationResolver.isListening(.listening))
        XCTAssertTrue(VoiceInvocationResolver.isListening(.liveSession))
        XCTAssertTrue(VoiceInvocationResolver.isListening(.thinking))
        XCTAssertFalse(VoiceInvocationResolver.isListening(.standby))
        XCTAssertFalse(VoiceInvocationResolver.isListening(.speaking))
        XCTAssertFalse(VoiceInvocationResolver.isListening(.busy))
    }

    func testTheDeadlineIsAFewSeconds() {
        XCTAssertGreaterThanOrEqual(VoiceInvocationResolver.answerDeadline, .seconds(2))
        XCTAssertLessThanOrEqual(VoiceInvocationResolver.answerDeadline, .seconds(8))
    }

    /// A live session started this way is the wearer asking.
    func testAVoiceInvocationIsAnExplicitLiveActivation() {
        XCTAssertTrue(LiveActivationSource.voiceInvocation.isExplicit)
    }
}

/// The support report's record of each glasses' requests (Plan JV P1).
@MainActor
final class VoiceInvocationLedgerTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() -> VoiceInvocationLedger {
        VoiceInvocationLedger(now: { [unowned self] in self.clock })
    }

    func testNothingRecordedIsNoLines() {
        XCTAssertEqual(ledger().reportLines, [])
    }

    func testDevicesAreNumberedByFirstSightAndNeverNamed() {
        let ledger = ledger()
        ledger.record(.streamStarted, device: "SECRET-DEVICE-B")
        ledger.record(.streamStarted, device: "SECRET-DEVICE-A")
        ledger.record(.received(.init(runState: .background, protectedDataAvailable: false)), device: "SECRET-DEVICE-A")
        let lines = ledger.reportLines
        XCTAssertEqual(lines.first, "Voice invocations: 1 received since launch")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].hasPrefix("  glasses 1 · "))
        XCTAssertTrue(lines[2].hasPrefix("  glasses 2 · "))
        XCTAssertTrue(lines[3].hasSuffix("received (app background, phone locked)"))
        XCTAssertFalse(lines.joined().contains("SECRET"))
    }

    func testALinkDropAfterARequestSaysHowLongAfter() {
        let ledger = ledger()
        ledger.record(.received(.init(runState: .active, protectedDataAvailable: true)), device: "g")
        clock += 12
        XCTAssertEqual(ledger.secondsSinceLastInvocation(on: "g"), 12)
        XCTAssertNil(ledger.secondsSinceLastInvocation(on: "other"))
        ledger.record(.streamStopped(.linkDown, secondsSinceLastInvocation: ledger.secondsSinceLastInvocation(on: "g")),
                      device: "g")
        XCTAssertTrue(ledger.reportLines.last!.hasSuffix("stream stopped (linkDown, 12 s after the last invocation)"))
    }

    func testAnswersAreDescribed() {
        XCTAssertEqual(VoiceInvocationLedger.describe(.answered(outcome: "startListening", answer: .success,
                                                                milliseconds: 420, delivered: true)),
                       "answered success after 420 ms, outcome startListening, delivered")
        XCTAssertEqual(VoiceInvocationLedger.describe(.answered(outcome: "timedOut", answer: .failure(.timedOut),
                                                                milliseconds: 5000, delivered: false)),
                       "answered failure (timedOut) after 5000 ms, outcome timedOut, not delivered")
        XCTAssertEqual(VoiceInvocationLedger.describe(.error(.channelNotConnected, secondsSinceLastInvocation: nil)),
                       "stream error channelNotConnected")
    }

    func testEachDeviceKeepsItsLatestEntries() {
        let ledger = ledger()
        for _ in 0..<(VoiceInvocationLedger.capacity + 5) {
            ledger.record(.streamStarted, device: "g")
        }
        XCTAssertEqual(ledger.entries["g"]?.count, VoiceInvocationLedger.capacity)
    }

    func testOutcomeTokensAreLogSafe() {
        let outcomes: [VoiceInvocationOutcome] = [.run(.startListening), .run(.interruptAndListen), .alreadyListening]
            + VoiceInvocationRefusal.allCases.map { .refuse($0) }
        for outcome in outcomes {
            XCTAssertEqual(PrivacyToken(outcome.reportToken).description, outcome.reportToken)
        }
    }
}
