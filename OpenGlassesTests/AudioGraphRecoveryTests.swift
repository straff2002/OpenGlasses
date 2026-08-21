import XCTest
@testable import OpenGlasses

/// Plan CW P1. The restart-vs-rebuild decision for a realtime audio graph — the logic that
/// previously sat as three booleans read inline on the lifecycle queue, where none of these
/// combinations could be produced without hardware.
final class AudioGraphRecoveryTests: XCTestCase {

    private func state(
        engineRunning: Bool = true,
        nodesAttached: Bool = true,
        formatChanged: Bool = false,
        isCapturing: Bool = true
    ) -> AudioGraphState {
        AudioGraphState(
            engineRunning: engineRunning,
            nodesAttached: nodesAttached,
            formatChanged: formatChanged,
            isCapturing: isCapturing
        )
    }

    private func action(
        _ state: AudioGraphState,
        trigger: AudioGraphTrigger = .routeChange
    ) -> AudioGraphAction {
        AudioGraphRecovery.action(for: trigger, state: state)
    }

    // MARK: - The four rules

    /// The bug the plan exists for: nodes wired, format unchanged, engine merely stopped by the
    /// session-start route settle. Restarting keeps the already-scheduled first reply.
    func testStoppedEngineWithIntactGraphRestarts() {
        XCTAssertEqual(action(state(engineRunning: false)), .restart)
    }

    func testDetachedNodesRebuildAndCarryPlayback() {
        XCTAssertEqual(
            action(state(nodesAttached: false)),
            .rebuild(carryPlayback: true)
        )
    }

    /// A tap and converter built for one rate produce garbage on another, so a format change
    /// rebuilds unconditionally — and the scheduled buffers cannot come along.
    func testFormatChangeRebuildsWithoutCarryingPlayback() {
        XCTAssertEqual(
            action(state(formatChanged: true)),
            .rebuild(carryPlayback: false)
        )
    }

    func testNotCapturingDoesNothing() {
        XCTAssertEqual(action(state(isCapturing: false)), .none)
    }

    func testIntactRunningGraphDoesNothing() {
        XCTAssertEqual(action(state()), .none)
    }

    // MARK: - Precedence between rules

    /// Format change outranks a detached graph: both rebuild, but carrying buffers that no longer
    /// match the output format would schedule garbage. Losing them is correct; losing them
    /// *silently* is what P2 fixes.
    func testFormatChangeOutranksDetachedNodes() {
        XCTAssertEqual(
            action(state(nodesAttached: false, formatChanged: true)),
            .rebuild(carryPlayback: false)
        )
    }

    /// A detached graph outranks a merely-stopped engine — `start()` on a graph with no player
    /// node attached would come up silent.
    func testDetachedNodesOutrankStoppedEngine() {
        XCTAssertEqual(
            action(state(engineRunning: false, nodesAttached: false)),
            .rebuild(carryPlayback: true)
        )
    }

    /// A format change is worth acting on even while the engine is still running: the tap is
    /// already producing garbage, and nothing else would notice.
    func testFormatChangeActsOnARunningEngine() {
        XCTAssertEqual(
            action(state(engineRunning: true, formatChanged: true)),
            .rebuild(carryPlayback: false)
        )
    }

    /// `isCapturing` is checked before everything: a torn-down engine we are not capturing on is
    /// not a fault to repair.
    func testNotCapturingOutranksEveryFaultSignal() {
        XCTAssertEqual(
            action(state(engineRunning: false,
                         nodesAttached: false,
                         formatChanged: true,
                         isCapturing: false)),
            .none
        )
    }

    // MARK: - Trigger invariance

    /// Pins Plan CW's open question honestly: the table is the same for every trigger today,
    /// because whether `.newDeviceAvailable` deserves its own branch needs P4's field data. If a
    /// per-trigger branch is ever added, this test is where the decision has to be made explicitly.
    func testDecisionIsInvariantAcrossTriggers() {
        for engineRunning in [true, false] {
            for nodesAttached in [true, false] {
                for formatChanged in [true, false] {
                    for isCapturing in [true, false] {
                        let observed = state(engineRunning: engineRunning,
                                             nodesAttached: nodesAttached,
                                             formatChanged: formatChanged,
                                             isCapturing: isCapturing)
                        let expected = AudioGraphRecovery.action(for: .routeChange, state: observed)
                        for trigger in AudioGraphTrigger.allCases {
                            XCTAssertEqual(
                                AudioGraphRecovery.action(for: trigger, state: observed),
                                expected,
                                "\(trigger.rawValue) diverged on \(observed)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Every capturing state resolves to exactly one action, and no capturing fault resolves to
    /// `.none` — a fault we decline to act on is the failure mode this plan is about.
    func testEveryCapturingFaultProducesAnAction() {
        for engineRunning in [true, false] {
            for nodesAttached in [true, false] {
                for formatChanged in [true, false] {
                    let observed = state(engineRunning: engineRunning,
                                         nodesAttached: nodesAttached,
                                         formatChanged: formatChanged)
                    let isFaulty = !engineRunning || !nodesAttached || formatChanged
                    let result = AudioGraphRecovery.action(for: .routeChange, state: observed)
                    XCTAssertEqual(result != .none, isFaulty, "mismatch on \(observed)")
                }
            }
        }
    }

    // MARK: - Format comparison

    func testIdenticalFormatIsUnchanged() {
        XCTAssertFalse(AudioGraphRecovery.formatChanged(
            fromSampleRate: 48000, fromChannels: 1,
            toSampleRate: 48000, toChannels: 1
        ))
    }

    /// The case that matters: a phone mic at 48 kHz replaced by a glasses HFP link at 8 kHz.
    func testHFPDowngradeIsAFormatChange() {
        XCTAssertTrue(AudioGraphRecovery.formatChanged(
            fromSampleRate: 48000, fromChannels: 1,
            toSampleRate: 8000, toChannels: 1
        ))
    }

    func testChannelCountChangeIsAFormatChange() {
        XCTAssertTrue(AudioGraphRecovery.formatChanged(
            fromSampleRate: 48000, fromChannels: 1,
            toSampleRate: 48000, toChannels: 2
        ))
    }

    /// Hardware re-reports the same rate with sub-Hz drift. Treating that as a change would tear
    /// down a working graph — and destroy the queued reply — over a rounding artefact.
    func testSubHertzDriftIsNotAFormatChange() {
        XCTAssertFalse(AudioGraphRecovery.formatChanged(
            fromSampleRate: 48000.0, fromChannels: 1,
            toSampleRate: 48000.000001, toChannels: 1
        ))
    }

    /// The tolerance is tight enough that no real rate pair hides inside it.
    func testToleranceDoesNotSwallowARealRateChange() {
        XCTAssertTrue(AudioGraphRecovery.formatChanged(
            fromSampleRate: 24000, fromChannels: 1,
            toSampleRate: 16000, toChannels: 1
        ))
    }

    /// A zero rate is the known dead-IO signature; it must read as a change rather than as "same
    /// enough", or a restart into a deaf input node would report success.
    func testZeroSampleRateReadsAsAFormatChange() {
        XCTAssertTrue(AudioGraphRecovery.formatChanged(
            fromSampleRate: 48000, fromChannels: 1,
            toSampleRate: 0, toChannels: 1
        ))
    }
}
