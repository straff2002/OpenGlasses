import XCTest
@testable import OpenGlasses

/// A live broadcast used to connect once and then assume the connection held forever: nothing
/// watched the socket, so a mid-stream drop just silently ended the stream while frames kept being
/// pushed at a dead encoder. These cover the decision layer that replaced that assumption — the
/// backoff, the session's legal transitions, the bitrate adaptation, and the achieved-frame-rate
/// meter — all of which are exactly the parts that cannot be exercised against a real ingest.
@MainActor
final class BroadcastResilienceTests: XCTestCase {

    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    // MARK: - Reconnect policy

    func testBackoffDoublesFromOneSecond() {
        var policy = BroadcastReconnectPolicy()
        policy.recordLive(at: at(0))

        XCTAssertEqual(policy.connectionLost(now: at(10)), .retry(attempt: 1, delay: 1))
        XCTAssertEqual(policy.connectionLost(now: at(11)), .retry(attempt: 2, delay: 2))
        XCTAssertEqual(policy.connectionLost(now: at(13)), .retry(attempt: 3, delay: 4))
        XCTAssertEqual(policy.connectionLost(now: at(17)), .retry(attempt: 4, delay: 8))
    }

    func testBackoffIsCappedAtOneMinute() {
        let policy = BroadcastReconnectPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 6), 32)   // last one under the cap
        XCTAssertEqual(policy.delay(forAttempt: 7), 60)   // 64 would be, so it is clamped
        XCTAssertEqual(policy.delay(forAttempt: 12), 60)
        // The cap must hold for an attempt count large enough to overflow the doubling — an
        // uncapped `pow` reaches `.infinity` there, and `min` with infinity is only accidentally
        // correct.
        XCTAssertEqual(policy.delay(forAttempt: 200), 60)
    }

    func testFirstAttemptIsIndexedFromOne() {
        var policy = BroadcastReconnectPolicy()
        guard case .retry(let attempt, _) = policy.connectionLost(now: at(0)) else {
            return XCTFail("expected a retry")
        }
        XCTAssertEqual(attempt, 1)
    }

    func testAttemptCounterSurvivesAFlappingConnection() {
        // Connect, drop immediately, reconnect, drop immediately: the backoff must keep growing,
        // or a link that flaps every two seconds becomes a retry loop hammering the ingest.
        var policy = BroadcastReconnectPolicy()
        XCTAssertEqual(policy.connectionLost(now: at(0)), .retry(attempt: 1, delay: 1))
        policy.recordLive(at: at(2))
        XCTAssertEqual(policy.connectionLost(now: at(4)), .retry(attempt: 2, delay: 2))
        policy.recordLive(at: at(6))
        XCTAssertEqual(policy.connectionLost(now: at(9)), .retry(attempt: 3, delay: 4))
    }

    func testAStableStretchForgivesTheAttemptCounter() {
        var policy = BroadcastReconnectPolicy()
        XCTAssertEqual(policy.connectionLost(now: at(0)), .retry(attempt: 1, delay: 1))
        XCTAssertEqual(policy.connectionLost(now: at(2)), .retry(attempt: 2, delay: 2))

        // Ran clean for the full stable window, so the next drop is a fresh problem.
        policy.recordLive(at: at(10))
        XCTAssertEqual(policy.connectionLost(now: at(80)), .retry(attempt: 1, delay: 1))
    }

    func testStabilityResetAlsoRestartsTheGiveUpBudget() {
        var policy = BroadcastReconnectPolicy()
        _ = policy.connectionLost(now: at(0))
        policy.recordLive(at: at(5))
        // Live for well past the stable window, then a drop far beyond the give-up horizon
        // measured from the *original* failure — it must still retry, not give up.
        XCTAssertEqual(policy.connectionLost(now: at(400)), .retry(attempt: 1, delay: 1))
    }

    func testGivesUpAfterTheRetryBudgetIsSpent() {
        var policy = BroadcastReconnectPolicy(giveUpAfter: 300)
        XCTAssertEqual(policy.connectionLost(now: at(0)), .retry(attempt: 1, delay: 1))
        XCTAssertEqual(policy.connectionLost(now: at(299)), .retry(attempt: 2, delay: 2))
        XCTAssertEqual(policy.connectionLost(now: at(300)), .giveUp)
    }

    func testResetClearsEverything() {
        var policy = BroadcastReconnectPolicy()
        _ = policy.connectionLost(now: at(0))
        _ = policy.connectionLost(now: at(1))
        policy.reset()
        XCTAssertEqual(policy.attempt, 0)
        XCTAssertNil(policy.firstFailureAt)
        XCTAssertEqual(policy.connectionLost(now: at(2)), .retry(attempt: 1, delay: 1))
    }

    // MARK: - Session state machine

    func testHappyPathGoesIdleConnectingLive() {
        var machine = BroadcastSessionMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(machine.apply(.start))
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertTrue(machine.apply(.connected))
        XCTAssertEqual(machine.state, .live)
    }

    func testDropFromLiveEntersReconnecting() {
        var machine = BroadcastSessionMachine(state: .live)
        XCTAssertTrue(machine.apply(.dropped))
        XCTAssertEqual(machine.state, .reconnecting(attempt: 1))
    }

    func testASecondDropReportIsRejected() {
        // Both status streams report the same death; the second must not restart a reconnect
        // that is already running.
        var machine = BroadcastSessionMachine(state: .live)
        XCTAssertTrue(machine.apply(.dropped))
        XCTAssertFalse(machine.apply(.dropped))
        XCTAssertEqual(machine.state, .reconnecting(attempt: 1))
    }

    func testReconnectingCountsUp() {
        var machine = BroadcastSessionMachine(state: .live)
        machine.apply(.dropped)
        XCTAssertTrue(machine.apply(.retry(attempt: 2)))
        XCTAssertEqual(machine.state, .reconnecting(attempt: 2))
        // The same attempt number twice is not a change.
        XCTAssertFalse(machine.apply(.retry(attempt: 2)))
    }

    func testReconnectSuccessReturnsToLive() {
        var machine = BroadcastSessionMachine(state: .reconnecting(attempt: 4))
        XCTAssertTrue(machine.apply(.connected))
        XCTAssertEqual(machine.state, .live)
    }

    func testIdleSessionRejectsEverythingButStart() {
        for event: BroadcastSessionEvent in [.connected, .dropped, .retry(attempt: 1), .fail("x")] {
            var machine = BroadcastSessionMachine()
            XCTAssertFalse(machine.apply(event), "\(event) should not be legal from idle")
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testAConnectingSessionCannotDrop() {
        // A failure before the publish is a failed connect, reported as `.fail` — routing it
        // through `.dropped` would start a reconnect for a stream that was never live.
        var machine = BroadcastSessionMachine(state: .connecting)
        XCTAssertFalse(machine.apply(.dropped))
        XCTAssertEqual(machine.state, .connecting)
    }

    func testStopIsAlwaysLegal() {
        for state: BroadcastSessionState in [.connecting, .live, .reconnecting(attempt: 3),
                                             .failed("boom")] {
            var machine = BroadcastSessionMachine(state: state)
            XCTAssertTrue(machine.apply(.stop))
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testFailedSessionCanBeStartedAgain() {
        var machine = BroadcastSessionMachine(state: .failed("bad key"))
        XCTAssertTrue(machine.apply(.start))
        XCTAssertEqual(machine.state, .connecting)
    }

    func testStateFlags() {
        XCTAssertTrue(BroadcastSessionState.live.isLive)
        XCTAssertFalse(BroadcastSessionState.reconnecting(attempt: 1).isLive)
        XCTAssertTrue(BroadcastSessionState.connecting.isConnecting)
        XCTAssertTrue(BroadcastSessionState.reconnecting(attempt: 9).isConnecting)
        XCTAssertFalse(BroadcastSessionState.failed("x").isConnecting)
    }

    // MARK: - Adaptive bitrate

    private func makePolicy(ceiling: Int = 4_000_000,
                            floor: Int = 800_000) -> AdaptiveBitratePolicy {
        AdaptiveBitratePolicy(ceiling: ceiling, floor: floor)
    }

    private func healthy(_ target: Int, queue: Int = 0) -> BroadcastPressureSample {
        BroadcastPressureSample(targetBitrate: target, measuredBitrate: target, queuedBytes: queue)
    }

    func testHealthyLinkHolds() {
        var policy = makePolicy()
        XCTAssertEqual(policy.evaluate(healthy(4_000_000)), .hold)
        XCTAssertEqual(policy.evaluate(healthy(4_000_000)), .hold)
    }

    func testStarvedLinkStepsDownAQuarter() {
        var policy = makePolicy()
        let sample = BroadcastPressureSample(targetBitrate: 4_000_000,
                                             measuredBitrate: 2_000_000,
                                             queuedBytes: 0)
        XCTAssertEqual(policy.evaluate(sample), .stepDown(to: 3_000_000))
    }

    func testTransportBackpressureStepsDownEvenWhenThroughputLooksFine() {
        // The transport's own verdict outranks a single healthy-looking throughput sample: it is
        // watching the queue grow across samples, which one number cannot show.
        var policy = makePolicy()
        let sample = BroadcastPressureSample(targetBitrate: 4_000_000,
                                             measuredBitrate: 4_000_000,
                                             queuedBytes: 90_000,
                                             insufficientBandwidth: true)
        XCTAssertEqual(policy.evaluate(sample), .stepDown(to: 3_000_000))
    }

    func testAGrowingQueueStepsDown() {
        var policy = makePolicy()
        XCTAssertEqual(policy.evaluate(healthy(4_000_000, queue: 1_000)), .hold)
        XCTAssertEqual(policy.evaluate(healthy(4_000_000, queue: 5_000)), .hold)
        // Third consecutive growth is the signal.
        XCTAssertEqual(policy.evaluate(healthy(4_000_000, queue: 9_000)), .stepDown(to: 3_000_000))
    }

    func testASteadyQueueIsNotBackpressure() {
        var policy = makePolicy()
        for _ in 0..<6 {
            XCTAssertNotEqual(policy.evaluate(healthy(4_000_000, queue: 5_000)),
                              .stepDown(to: 3_000_000))
        }
    }

    func testStepDownNeverGoesBelowTheFloor() {
        var policy = makePolicy(floor: 800_000)
        let sample = BroadcastPressureSample(targetBitrate: 900_000,
                                             measuredBitrate: 100_000,
                                             queuedBytes: 0)
        XCTAssertEqual(policy.evaluate(sample), .stepDown(to: 800_000))
    }

    func testAtTheFloorAStarvedLinkHolds() {
        var policy = makePolicy(floor: 800_000)
        let sample = BroadcastPressureSample(targetBitrate: 800_000,
                                             measuredBitrate: 100_000,
                                             queuedBytes: 0)
        XCTAssertEqual(policy.evaluate(sample), .hold)
    }

    func testRecoveryNeedsASustainedHealthyWindow() {
        var policy = makePolicy(ceiling: 4_000_000)
        // Four healthy samples are not enough.
        for _ in 0..<4 {
            XCTAssertEqual(policy.evaluate(healthy(2_000_000)), .hold)
        }
        XCTAssertEqual(policy.evaluate(healthy(2_000_000)), .stepUp(to: 2_400_000))
    }

    func testRecoveryStopsAtTheCeiling() {
        var policy = makePolicy(ceiling: 4_000_000)
        for _ in 0..<4 { _ = policy.evaluate(healthy(3_900_000)) }
        XCTAssertEqual(policy.evaluate(healthy(3_900_000)), .stepUp(to: 4_000_000))
    }

    func testAtTheCeilingRecoveryHolds() {
        var policy = makePolicy(ceiling: 4_000_000)
        for _ in 0..<10 {
            XCTAssertEqual(policy.evaluate(healthy(4_000_000)), .hold)
        }
    }

    func testPressureResetsTheRecoveryProgress() {
        var policy = makePolicy(ceiling: 4_000_000)
        for _ in 0..<4 { _ = policy.evaluate(healthy(2_000_000)) }
        // One bad sample throws away the accumulated healthy window...
        _ = policy.evaluate(BroadcastPressureSample(targetBitrate: 2_000_000,
                                                    measuredBitrate: 500_000,
                                                    queuedBytes: 0))
        // ...so the next healthy sample must not immediately step up.
        XCTAssertEqual(policy.evaluate(healthy(1_500_000)), .hold)
    }

    func testAZeroMeasurementIsNotEvidenceOfStarvation() {
        // The first sample of a session and any stats hiccup both read as zero. Treating that as
        // a starved link would walk a perfectly healthy stream down to the floor.
        var policy = makePolicy()
        let sample = BroadcastPressureSample(targetBitrate: 4_000_000,
                                             measuredBitrate: 0,
                                             queuedBytes: 0)
        XCTAssertEqual(policy.evaluate(sample), .hold)
    }

    func testRecoveryIsSlowerThanTheDrop() {
        // The asymmetry is the point: one decision removes 1 Mbps from a 4 Mbps target, and
        // getting it back takes several sustained-healthy windows.
        var policy = makePolicy(ceiling: 4_000_000)
        guard case .stepDown(let dropped) = policy.evaluate(
            BroadcastPressureSample(targetBitrate: 4_000_000,
                                    measuredBitrate: 1_000_000,
                                    queuedBytes: 0)) else {
            return XCTFail("expected a step down")
        }
        XCTAssertEqual(dropped, 3_000_000)

        var target = dropped
        var decisions = 0
        while target < 4_000_000, decisions < 50 {
            decisions += 1
            if case .stepUp(let next) = policy.evaluate(healthy(target)) { target = next }
        }
        XCTAssertEqual(target, 4_000_000)
        // ~3 step-ups at 5 samples each — an order of magnitude more observation than the drop.
        XCTAssertGreaterThanOrEqual(decisions, 10)
    }

    func testResetClearsQueueHistoryAndHealthyStreak() {
        var policy = makePolicy(ceiling: 4_000_000)
        for _ in 0..<4 { _ = policy.evaluate(healthy(2_000_000)) }
        policy.reset()
        XCTAssertEqual(policy.evaluate(healthy(2_000_000)), .hold)
    }

    func testCeilingBelowTheFloorIsClampedUp() {
        // A nonsense override must not produce a policy that can only step down.
        var policy = AdaptiveBitratePolicy(ceiling: 100_000, floor: 800_000)
        XCTAssertEqual(policy.ceiling, 800_000)
        XCTAssertEqual(policy.evaluate(healthy(800_000)), .hold)
    }

    // MARK: - Frame rate meter

    func testMeterReportsZeroBeforeItHasASpan() {
        var meter = BroadcastFrameRateMeter()
        XCTAssertEqual(meter.rate(), 0)
        meter.record(frames: 30, at: at(0))
        XCTAssertEqual(meter.rate(), 0)
    }

    func testMeterAveragesOverTheRetainedSpan() {
        var meter = BroadcastFrameRateMeter()
        meter.record(frames: 0, at: at(0))
        meter.record(frames: 30, at: at(1))
        meter.record(frames: 30, at: at(2))
        XCTAssertEqual(meter.rate(), 30, accuracy: 0.001)
    }

    func testMeterSeesAchievedRateBelowTheConfiguredOne() {
        // 30 fps configured, 6 arriving — the divergence the readout exists to show.
        var meter = BroadcastFrameRateMeter()
        for second in 0...5 {
            meter.record(frames: second == 0 ? 0 : 6, at: at(Double(second)))
        }
        XCTAssertEqual(meter.rate(), 6, accuracy: 0.001)
    }

    func testMeterForgetsSamplesOlderThanItsWindow() {
        var meter = BroadcastFrameRateMeter(window: 3)
        // A fast burst, then a long slow stretch: the burst must fall out of the average.
        meter.record(frames: 0, at: at(0))
        meter.record(frames: 100, at: at(1))
        for second in 2...8 {
            meter.record(frames: 5, at: at(Double(second)))
        }
        XCTAssertEqual(meter.rate(), 5, accuracy: 0.001)
    }

    func testMeterResets() {
        var meter = BroadcastFrameRateMeter()
        meter.record(frames: 0, at: at(0))
        meter.record(frames: 30, at: at(1))
        meter.reset()
        XCTAssertEqual(meter.rate(), 0)
    }

    // MARK: - Health readout

    func testHealthLabelsReadAsAStatusLine() {
        let health = BroadcastHealth(state: .live,
                                     configuredFrameRate: 30,
                                     achievedFrameRate: 28.6,
                                     targetBitrate: 3_000_000,
                                     measuredBitrate: 2_400_000,
                                     droppedFrameCount: 4,
                                     duration: 61,
                                     hasSentAnything: true)
        XCTAssertEqual(health.stateLabel, "Live")
        XCTAssertEqual(health.bitrateLabel, "2.4 Mbps")
        XCTAssertEqual(health.frameRateLabel, "29 fps")
    }

    func testHealthShowsTheTargetOnceSomethingIsActuallyFlowing() {
        // Between "the first bytes went out" and "the transport has reported a rate", the target
        // is the honest thing to show: it is what the encoder is aiming for, and something is
        // moving.
        let health = BroadcastHealth(state: .live, targetBitrate: 3_100_000, hasSentAnything: true)
        XCTAssertEqual(health.bitrateLabel, "3.1 Mbps")
    }

    func testAConnectionThatHasSentNothingShowsNoBitrateAtAll() {
        // The device readout that started this: "3.7 Mbps · 0 fps" on a connection the ingest
        // never received a byte from. The target described an intention; printing it next to the
        // measurement that disproved it is the bug.
        let health = BroadcastHealth(state: .live,
                                     achievedFrameRate: 0,
                                     targetBitrate: 3_700_000,
                                     hasSentAnything: false)
        XCTAssertEqual(health.bitrateLabel, "—")
        XCTAssertEqual(health.stateLabel, "Nothing sent yet")
    }

    func testHealthRendersSubMegabitRatesInKilobits() {
        let health = BroadcastHealth(state: .live, targetBitrate: 0, measuredBitrate: 820_000,
                                     hasSentAnything: true)
        XCTAssertEqual(health.bitrateLabel, "820 kbps")
    }

    func testHealthHasNoBitrateToShowWhenNothingIsRunning() {
        XCTAssertEqual(BroadcastHealth().bitrateLabel, "—")
    }

    func testReconnectingLabelNamesTheAttempt() {
        let health = BroadcastHealth(state: .reconnecting(attempt: 3))
        XCTAssertEqual(health.stateLabel, "Reconnecting 3")
    }

    // MARK: - Connected, and sending nothing

    func testFlowingIsNeverCalledStalledHoweverLongItRuns() {
        XCTAssertEqual(
            BroadcastStallPolicy.verdict(secondsSinceStart: 600, hasSentAnything: true), .flowing)
    }

    func testTheGracePeriodCoversAHandshakeAndThePriming() {
        XCTAssertEqual(
            BroadcastStallPolicy.verdict(secondsSinceStart: 3, hasSentAnything: false), .tooEarly)
    }

    func testSilencePastTheGracePeriodIsAStall() {
        XCTAssertEqual(
            BroadcastStallPolicy.verdict(secondsSinceStart: 9, hasSentAnything: false), .stalled)
    }

    func testPrivateAddressesAreRecognisedAsLocalNetwork() {
        for target in ["rtmp://192.168.1.103:1935/live", "10.0.0.4", "172.20.3.9",
                       "rtmp://mediaserver.local/live", "localhost", "169.254.1.1"] {
            XCTAssertTrue(BroadcastStallPolicy.isPrivateNetworkHost(target), target)
        }
    }

    func testPublicIngestsAreNotTreatedAsLocalNetwork() {
        for target in ["rtmp://a.rtmp.youtube.com/live2", "203.0.113.7", "172.32.0.1",
                       "192.169.1.1", ""] {
            XCTAssertFalse(BroadcastStallPolicy.isPrivateNetworkHost(target), target)
        }
    }

    func testHostIsTakenOutOfAFullRTMPURL() {
        XCTAssertEqual(BroadcastStallPolicy.host(from: "rtmp://192.168.1.103:1935/live"),
                       "192.168.1.103")
        XCTAssertEqual(BroadcastStallPolicy.host(from: "rtmp://user:pw@host.example/app"),
                       "host.example")
        XCTAssertEqual(BroadcastStallPolicy.host(from: "192.168.1.103"), "192.168.1.103")
    }

    func testAStalledLocalTargetNamesTheLocalNetworkSetting() {
        let message = BroadcastStallPolicy.stalledMessage(target: "rtmp://192.168.1.103:1935/live")
        XCTAssertTrue(message.contains("Local Network"), message)
    }

    func testAStallIsADropSoTheReconnectMachineryGetsItsShot() {
        // A session that published and then wrote nothing is dead, and the session machine has to
        // agree — otherwise the stall is a message next to a stream that idles forever instead of
        // retrying. A fresh connection may well come up writable.
        var machine = BroadcastSessionMachine()
        machine.apply(.start)
        XCTAssertTrue(machine.apply(.connected))
        XCTAssertTrue(machine.apply(.dropped),
                      "a zero-bytes stall must be accepted as a drop from live")
        XCTAssertEqual(machine.state, .reconnecting(attempt: 1))
    }

    func testAStalledPublicTargetDoesNotBlameAPermissionItCannotHaveHit() {
        let message = BroadcastStallPolicy.stalledMessage(target: "rtmp://a.rtmp.youtube.com/live2")
        XCTAssertFalse(message.contains("Local Network"), message)
        XCTAssertTrue(message.contains("stream key"), message)
    }
}
