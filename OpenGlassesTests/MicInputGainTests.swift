import XCTest
@testable import OpenGlasses

/// Plan CU P2 rider — the normaliser that makes one threshold pair mean the same thing on a phone
/// mic at arm's length and a glasses mic at the temple.
final class MicInputGainTests: XCTestCase {

    func testAQuietRouteIsAmplifiedTowardTheTarget() {
        var gain = MicInputGain()
        let quiet: Float = MicInputGain.targetRMS / 4
        let applied = gain.gain(forHopRMS: quiet, route: .phone)
        XCTAssertGreaterThan(applied, 1.0)
        XCTAssertEqual(quiet * applied, MicInputGain.targetRMS, accuracy: 0.005)
    }

    func testALoudRouteIsAttenuated() {
        var gain = MicInputGain()
        let loud: Float = MicInputGain.targetRMS * 4
        XCTAssertLessThan(gain.gain(forHopRMS: loud, route: .glasses), 1.0)
    }

    /// The trap this guard exists for: in a quiet room every hop is below the noise floor, the
    /// estimate walks toward zero, the gain walks to the ceiling, and the first thing amplified into
    /// the detector is exactly the noise the threshold was raised to ignore.
    func testHopsBelowTheNoiseFloorDoNotMoveTheEstimate() {
        var gain = MicInputGain()
        _ = gain.gain(forHopRMS: MicInputGain.targetRMS, route: .phone)
        let learned = gain.level(for: .phone)

        for _ in 0..<200 {
            _ = gain.gain(forHopRMS: TranscriptGuard.defaultRMSThreshold / 10, route: .phone)
        }
        XCTAssertEqual(gain.level(for: .phone), learned,
                       "silence must teach the normaliser nothing")
    }

    func testGainIsClamped() {
        var gain = MicInputGain()
        let onSilence = gain.gain(forHopRMS: 0, route: .phone)
        XCTAssertEqual(onSilence, 1.0, "with nothing learned yet, leave the signal alone")

        for _ in 0..<500 { _ = gain.gain(forHopRMS: 10.0, route: .glasses) }
        XCTAssertGreaterThanOrEqual(gain.gain(forHopRMS: 10.0, route: .glasses),
                                    MicInputGain.range.lowerBound)
    }

    /// Why `micRoute` is a cohort tag and not a footnote: the two mics are different populations,
    /// and one's level must never describe the other.
    func testRoutesKeepSeparateEstimates() {
        var gain = MicInputGain()
        for _ in 0..<100 { _ = gain.gain(forHopRMS: 0.2, route: .glasses) }
        XCTAssertNil(gain.level(for: .phone))
        XCTAssertNotNil(gain.level(for: .glasses))
        XCTAssertEqual(gain.gain(forHopRMS: MicInputGain.targetRMS, route: .phone), 1.0, accuracy: 0.001)
    }

    /// A level learned at 48 kHz from the phone mic describes nothing about the 8 kHz link that
    /// replaced it — which is why a format change forgets the route.
    func testForgettingARouteDropsItsLevel() {
        var gain = MicInputGain()
        _ = gain.gain(forHopRMS: 0.2, route: .glasses)
        gain.forget(route: .glasses)
        XCTAssertNil(gain.level(for: .glasses))
    }

    /// The estimate follows the room, not each syllable: one loud hop must not re-tune the mic.
    func testTheEstimateMovesSlowly() {
        var gain = MicInputGain()
        for _ in 0..<50 { _ = gain.gain(forHopRMS: 0.02, route: .phone) }
        let settled = gain.level(for: .phone) ?? 0
        _ = gain.gain(forHopRMS: 0.5, route: .phone)          // one shout
        let after = gain.level(for: .phone) ?? 0
        XCTAssertLessThan(after - settled, 0.05,
                          "a single hop may nudge the estimate; it may not redefine it")
    }
}
