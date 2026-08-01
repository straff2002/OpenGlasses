import XCTest
@testable import OpenGlasses

/// Plan CF — the redial rule: `.startSession` appears exactly when a live call existed at
/// switch time and the target is a realtime mode.
final class ModeSwitchPolicyTests: XCTestCase {

    func testMidCallSwitchBetweenRealtimeModesRedials() {
        let actions = ModeSwitchPolicy.actions(from: .geminiLive, to: .openaiRealtime,
                                               wasSessionActive: true, autoRedial: true)
        XCTAssertEqual(actions, [
            .teardown(.geminiLive),
            .settleDelay,
            .startSubstrate(.openaiRealtime),
            .startSession(.openaiRealtime),
        ])
    }

    func testRedialWorksInBothDirections() {
        let actions = ModeSwitchPolicy.actions(from: .openaiRealtime, to: .geminiLive,
                                               wasSessionActive: true, autoRedial: true)
        XCTAssertEqual(actions.last, .startSession(.geminiLive))
    }

    func testIdleSwitchNeverStartsASession() {
        let actions = ModeSwitchPolicy.actions(from: .geminiLive, to: .openaiRealtime,
                                               wasSessionActive: false, autoRedial: true)
        XCTAssertEqual(actions, [
            .teardown(.geminiLive),
            .settleDelay,
            .startSubstrate(.openaiRealtime),
        ])
    }

    func testSwitchingFromDirectNeverFabricatesACall() {
        // From Direct, wasSessionActive is false by construction (it is only measured on the
        // realtime managers) — but even a buggy caller passing true must not matter for a
        // Direct *target*; for a realtime target the flag is the caller's contract.
        let toDirect = ModeSwitchPolicy.actions(from: .geminiLive, to: .direct,
                                                wasSessionActive: true, autoRedial: true)
        XCTAssertFalse(toDirect.contains { if case .startSession = $0 { return true }; return false },
                       "switching to Direct is handled by the wake-word substrate, not a session")
    }

    func testAutoRedialOffRestoresOldBehavior() {
        let actions = ModeSwitchPolicy.actions(from: .geminiLive, to: .openaiRealtime,
                                               wasSessionActive: true, autoRedial: false)
        XCTAssertFalse(actions.contains { if case .startSession = $0 { return true }; return false })
    }

    func testSequenceOrderingInvariants() {
        // Whatever the inputs: teardown first, redial (when present) last, exactly one settle
        // delay between teardown and substrate.
        for wasActive in [true, false] {
            let actions = ModeSwitchPolicy.actions(from: .openaiRealtime, to: .geminiLive,
                                                   wasSessionActive: wasActive, autoRedial: true)
            XCTAssertEqual(actions.first, .teardown(.openaiRealtime))
            XCTAssertEqual(actions[1], .settleDelay)
            XCTAssertEqual(actions[2], .startSubstrate(.geminiLive))
            if wasActive {
                XCTAssertEqual(actions.last, .startSession(.geminiLive))
                XCTAssertEqual(actions.count, 4)
            } else {
                XCTAssertEqual(actions.count, 3)
            }
        }
    }
}
