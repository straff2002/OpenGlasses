import XCTest
@testable import OpenGlasses

/// Plan FE P5 — how the approved voice visuals consume the playback-activity level.
///
/// The one thing that must not regress is that the *approved* design is still exactly what ships
/// when there is no signal: an engine with no meter, a wearer with Reduce Motion on, or anything
/// that is not speaking all get the parameters that were signed off, not something near them.
final class WavelineParamsTests: XCTestCase {

    private let states: [VoiceVisualState] = [.idle, .listening, .thinking, .speaking]

    // MARK: - No signal is the approved design

    /// `nil` activity is identical to the state-only parameters — every state, exactly equal.
    func testNilActivityIsIdenticalToTheApprovedParameters() {
        for state in states {
            XCTAssertEqual(WavelineParams.params(for: state, activity: nil),
                           WavelineParams.params(for: state),
                           "\(state) changed with no signal")
        }
        XCTAssertEqual(WavelineParams.activityMultiplier(nil), 1)
    }

    /// The level describes playback, so it says nothing about listening, thinking or idling —
    /// those states ignore it however loud it claims to be.
    func testOnlySpeakingScalesWithActivity() {
        for state in states where state != .speaking {
            for activity in [0.0, 0.5, 1.0] {
                XCTAssertEqual(WavelineParams.params(for: state, activity: activity),
                               WavelineParams.params(for: state),
                               "\(state) scaled with activity \(activity)")
            }
        }
    }

    // MARK: - The bound

    /// The scaling stays inside the declared band, so the design's shape survives: the quietest
    /// reactive speaking wave is still taller than thinking, and the loudest cannot escape 1.4×.
    func testScalingIsBoundedAndPreservesProportions() {
        let base = WavelineParams.params(for: .speaking)
        for activity in stride(from: -0.5, through: 1.5, by: 0.05) {
            let scaled = WavelineParams.params(for: .speaking, activity: activity)
            let factor = scaled.slow / base.slow
            XCTAssertGreaterThanOrEqual(factor, WavelineParams.activityAmplitudeScale.lowerBound - 1e-9)
            XCTAssertLessThanOrEqual(factor, WavelineParams.activityAmplitudeScale.upperBound + 1e-9)
            // All three harmonics move together — the wave breathes, it does not change shape.
            XCTAssertEqual(scaled.mid / base.mid, factor, accuracy: 1e-9)
            XCTAssertEqual(scaled.fast / base.fast, factor, accuracy: 1e-9)
        }

        XCTAssertEqual(WavelineParams.activityMultiplier(0),
                       WavelineParams.activityAmplitudeScale.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(WavelineParams.activityMultiplier(1),
                       WavelineParams.activityAmplitudeScale.upperBound, accuracy: 1e-9)
        XCTAssertEqual(WavelineParams.activityMultiplier(-3),
                       WavelineParams.activityAmplitudeScale.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(WavelineParams.activityMultiplier(9),
                       WavelineParams.activityAmplitudeScale.upperBound, accuracy: 1e-9)
    }

    /// Even at its quietest, a reactive speaking wave still reads as speaking — the energy order
    /// the states were designed around is not something the live signal may invert.
    func testEnergyOrderSurvivesTheQuietestReactiveSpeakingWave() {
        let energy: (WavelineParams) -> Double = { $0.slow + $0.mid + $0.fast }
        let quietest = WavelineParams.params(for: .speaking, activity: 0)
        XCTAssertGreaterThan(energy(quietest), energy(WavelineParams.params(for: .thinking)))
        XCTAssertGreaterThan(energy(quietest), energy(WavelineParams.params(for: .idle)))
        XCTAssertGreaterThan(energy(quietest), energy(WavelineParams.params(for: .listening)))
    }

    /// Scaled parameters still obey the motion math's own invariants: anchored at both ends and
    /// inside the amplitude sum, which is what keeps the ribbon in its lane.
    func testScaledParametersStayAnchoredAndBounded() {
        for activity in [0.0, 0.3, 0.7, 1.0] {
            let params = WavelineParams.params(for: .speaking, activity: activity)
            let bound = params.slow + params.mid + params.fast + 1e-9
            for t in stride(from: 0.0, through: 4.0, by: 0.4) {
                XCTAssertEqual(WavelineParams.displacement(phase: 0, time: t, amplitudes: params),
                               0, accuracy: 1e-9)
                XCTAssertEqual(WavelineParams.displacement(phase: 1, time: t, amplitudes: params),
                               0, accuracy: 1e-9)
                for phase in stride(from: 0.0, through: 1.0, by: 0.05) {
                    XCTAssertLessThanOrEqual(
                        abs(WavelineParams.displacement(phase: phase, time: t, amplitudes: params)),
                        bound)
                }
            }
        }
    }

    // MARK: - Reduce Motion and the ambience

    /// Reduce Motion is unconditional: the held-steady radiance is the same value whatever the
    /// level claims, so the reactive scaling is off rather than merely damped.
    func testReduceMotionIgnoresTheActivityLevelEntirely() {
        let levels = Set(states.flatMap { state in
            [nil, 0.0, 0.5, 1.0].map { VoiceAmbience.glow(for: state, reduceMotion: true, activity: $0) }
        })
        XCTAssertEqual(levels.count, 1)
    }

    /// The ambience with no signal is exactly the approved radiance, and with one it breathes
    /// inside a narrow band around it — the screen stays lit by the assistant, never painted.
    func testAmbienceGlowIsUnchangedWithoutASignalAndBoundedWithOne() {
        for state in states {
            XCTAssertEqual(VoiceAmbience.glow(for: state, reduceMotion: false, activity: nil),
                           VoiceAmbience.glow(for: state, reduceMotion: false),
                           "\(state) changed with no signal")
        }
        for state in states where state != .speaking {
            XCTAssertEqual(VoiceAmbience.glow(for: state, reduceMotion: false, activity: 1.0),
                           VoiceAmbience.glow(for: state, reduceMotion: false))
        }

        let base = VoiceAmbience.glow(for: .speaking, reduceMotion: false)
        for activity in stride(from: -0.5, through: 1.5, by: 0.05) {
            let glow = VoiceAmbience.glow(for: .speaking, reduceMotion: false, activity: activity)
            XCTAssertGreaterThanOrEqual(glow, base * VoiceAmbience.activityGlowScale.lowerBound - 1e-9)
            XCTAssertLessThanOrEqual(glow, base * VoiceAmbience.activityGlowScale.upperBound + 1e-9)
            // Still a whisper: the reactive ambience never approaches an opacity you would call a
            // colour wash.
            XCTAssertLessThan(glow, 0.15)
        }
        XCTAssertGreaterThan(VoiceAmbience.glow(for: .speaking, reduceMotion: false, activity: 1.0),
                             VoiceAmbience.glow(for: .speaking, reduceMotion: false, activity: 0.0))
    }
}
