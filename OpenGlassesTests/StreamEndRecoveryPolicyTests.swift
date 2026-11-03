#if !AVENKIN_PHONE_ONLY
import MWDATCamera
import MWDATCore
import XCTest
@testable import OpenGlasses

// Plan HJ P0/P1 — what happens when a wanted glasses stream ends and does not come back by itself.
//
// The table is pure, so every row is proved here. The backend that asks it reaches `Wearables`,
// which traps in a unit-test process, so its wiring is held by the source guard at the bottom
// rather than executed.

final class StreamEndRecoveryPolicyTests: XCTestCase {

    private typealias Policy = StreamEndRecoveryPolicy

    private static let allPresences: [Policy.Presence] = [.foreground, .background, .locked]
    private static let stopRetrying = CameraErrorPolicy.RetryDisposition.stopRetrying(notice: "Too hot.")

    private static let allCauses: [Policy.Cause] = [
        .streamStopped,
        .streamError(.retryWithBackoff),
        .streamError(stopRetrying),
        .sessionError(.retryWithBackoff),
        .sessionError(stopRetrying),
        .compatibilityRefusal(notice: "Update."),
        .stallRecoveryFailed,
    ]

    private func decide(_ cause: Policy.Cause = .streamStopped,
                        presence: Policy.Presence = .foreground,
                        intended: Bool = true,
                        ours: Bool = false,
                        attempt: Int = 0,
                        recentEnds: Int = 1) -> Policy.Decision {
        Policy.decide(cause: cause, presence: presence, streamingIntended: intended,
                      transitionIsOurs: ours, attempt: attempt, recentEnds: recentEnds)
    }

    // MARK: - Row order

    /// Intent beats everything: no retry and no notice for a stream nobody wants, even when the
    /// error says nothing can be retried, the stream is flapping, or the budget is spent.
    func testIntentBeatsEverything() {
        for cause in Self.allCauses {
            for presence in Self.allPresences {
                for ours in [false, true] {
                    XCTAssertEqual(decide(cause, presence: presence, intended: false, ours: ours,
                                          attempt: 99, recentEnds: 99),
                                   .standDown, "\(cause) \(presence)")
                }
            }
        }
    }

    /// Ownership defers every cause except a failed stall recovery, which the owner reports as it
    /// lets go.
    func testOwnershipDefersEveryCauseExceptAFailedStallRecovery() {
        for cause in Self.allCauses where cause != .stallRecoveryFailed {
            XCTAssertEqual(decide(cause, ours: true),
                           .deferToOwner(after: StreamReconnectPolicy.deferToOwnerDelay), "\(cause)")
        }
        XCTAssertEqual(decide(.stallRecoveryFailed, ours: true), .retry(after: 1.5, attempt: 0))
    }

    /// The dead end this plan was written for: the stall detector's rebuild threw, the stream was
    /// unclaimed, the detector disarmed, and nothing tried again. The table must send it up the
    /// ladder.
    func testAFailedStallRecoveryClimbsTheLadderInsteadOfDeadEnding() {
        XCTAssertEqual(decide(.stallRecoveryFailed), .retry(after: 1.5, attempt: 0))
    }

    func testAnOrdinaryDropClimbsTheForegroundLadder() {
        XCTAssertEqual(decide(.streamStopped), .retry(after: 1.5, attempt: 0))
        XCTAssertEqual(decide(.streamError(.retryWithBackoff), attempt: 3), .retry(after: 3, attempt: 3))
        XCTAssertEqual(decide(.sessionError(.retryWithBackoff), attempt: 6), .retry(after: 5, attempt: 6))
    }

    // MARK: - Faults no retry clears

    func testAStreamFaultGivesUpInFrontAndParksOutOfIt() {
        let notice = CameraErrorPolicy.message(for: .thermalHot)
        let disposition = CameraErrorPolicy.retryDisposition(for: .thermalHot)
        XCTAssertEqual(decide(.streamError(disposition)), .giveUp(notice: notice))
        XCTAssertEqual(decide(.streamError(disposition), presence: .locked),
                       .parkUntilForeground(notice: Policy.parkedNotice(presence: .locked, reason: notice)))
        XCTAssertEqual(decide(.streamError(disposition), presence: .background),
                       .parkUntilForeground(notice: Policy.parkedNotice(presence: .background,
                                                                        reason: notice)))
    }

    func testASessionFaultGivesUpInFrontAndParksOutOfIt() {
        let disposition = CameraErrorPolicy.retryDisposition(for: DeviceSessionError.thermalCritical)
        XCTAssertEqual(disposition, .stopRetrying(notice: CameraErrorPolicy.deviceConditionNotice))
        XCTAssertEqual(decide(.sessionError(disposition)),
                       .giveUp(notice: CameraErrorPolicy.deviceConditionNotice))
        XCTAssertEqual(decide(.sessionError(disposition), presence: .locked),
                       .parkUntilForeground(notice: Policy.parkedNotice(
                           presence: .locked, reason: CameraErrorPolicy.deviceConditionNotice)))
    }

    /// Row 3a: no unlock updates the glasses' app or this build, so a refusal gives up wherever
    /// the phone is — ahead of the flap and budget rows too.
    func testACompatibilityRefusalGivesUpInEveryPresence() {
        let notice = DATCompatibilityMessage.appUpdateRequired
        for presence in Self.allPresences {
            XCTAssertEqual(decide(.compatibilityRefusal(notice: notice), presence: presence,
                                  attempt: 99, recentEnds: 99),
                           .giveUp(notice: notice), "\(presence)")
        }
    }

    func testAFaultOutranksTheFlapCount() {
        XCTAssertEqual(decide(.streamError(Self.stopRetrying), recentEnds: 99),
                       .giveUp(notice: "Too hot."))
    }

    // MARK: - The cause, built from what the backend saw

    func testASessionFaultWinsOverATransientStreamError() {
        XCTAssertEqual(Policy.cause(trigger: .streamStopped, streamFailure: .retryWithBackoff,
                                    sessionFailure: .classified(Self.stopRetrying)),
                       .sessionError(Self.stopRetrying))
        XCTAssertEqual(Policy.cause(trigger: .stallRecoveryFailed, streamFailure: .retryWithBackoff,
                                    sessionFailure: .classified(Self.stopRetrying)),
                       .sessionError(Self.stopRetrying))
    }

    func testACompatibilityRefusalWinsOverEverything() {
        XCTAssertEqual(Policy.cause(trigger: .stallRecoveryFailed, streamFailure: Self.stopRetrying,
                                    sessionFailure: .compatibilityRefusal(notice: "Update.")),
                       .compatibilityRefusal(notice: "Update."))
    }

    func testAStreamFaultWinsOverTheTrigger() {
        XCTAssertEqual(Policy.cause(trigger: .stallRecoveryFailed, streamFailure: Self.stopRetrying,
                                    sessionFailure: nil),
                       .streamError(Self.stopRetrying))
    }

    /// A transient error from the dying stream must not hide the handoff.
    func testAFailedStallRecoveryOutranksTransientErrors() {
        XCTAssertEqual(Policy.cause(trigger: .stallRecoveryFailed, streamFailure: .retryWithBackoff,
                                    sessionFailure: .classified(.retryWithBackoff)),
                       .stallRecoveryFailed)
    }

    func testWithoutAnErrorTheTriggerIsTheCause() {
        XCTAssertEqual(Policy.cause(trigger: .streamStopped, streamFailure: nil, sessionFailure: nil),
                       .streamStopped)
        XCTAssertEqual(Policy.cause(trigger: .streamStopped, streamFailure: .retryWithBackoff,
                                    sessionFailure: .classified(.retryWithBackoff)),
                       .sessionError(.retryWithBackoff))
        XCTAssertEqual(Policy.cause(trigger: .streamStopped, streamFailure: .retryWithBackoff,
                                    sessionFailure: nil),
                       .streamError(.retryWithBackoff))
    }

    // MARK: - Cadence and budget

    /// P1 must not change today's foreground behaviour by a single rung.
    func testTheForegroundCadenceIsTodaysLadder() {
        for attempt in -1...40 {
            XCTAssertEqual(Policy.reconnectDelay(attempt: attempt, presence: .foreground),
                           StreamRecoveryPolicy.reconnectDelay(attempt: attempt), "attempt \(attempt)")
        }
        XCTAssertEqual(Policy.reconnectBudget(presence: .foreground), StreamRecoveryPolicy.reconnectBudget)
    }

    func testTheBackgroundLadderIsSlowerAndShorter() {
        XCTAssertEqual(Policy.reconnectDelay(attempt: 0, presence: .locked), 3)
        XCTAssertEqual(Policy.reconnectDelay(attempt: 2, presence: .background), 10)
        XCTAssertNil(Policy.reconnectDelay(attempt: 7, presence: .locked))
        XCTAssertEqual(Policy.reconnectBudget(presence: .locked), 56)
        XCTAssertEqual(Policy.reconnectBudget(presence: .background),
                       Policy.reconnectBudget(presence: .locked))
        XCTAssertLessThan(Policy.reconnectBudget(presence: .locked),
                          Policy.reconnectBudget(presence: .foreground))
        XCTAssertEqual(decide(presence: .locked, attempt: 0), .retry(after: 3, attempt: 0))
    }

    func testASpentBudgetGivesUpInFrontAndParksOutOfIt() {
        XCTAssertEqual(decide(attempt: 21), .giveUp(notice: StreamRecoveryPolicy.reconnectGaveUpNotice))
        XCTAssertEqual(decide(presence: .locked, attempt: 7),
                       .parkUntilForeground(notice: Policy.parkedWhileLockedNotice))
        XCTAssertEqual(decide(presence: .background, attempt: 7),
                       .parkUntilForeground(notice: Policy.parkedInBackgroundNotice))
        // The rung the background ladder has spent is still a rung in front.
        XCTAssertEqual(decide(attempt: 7), .retry(after: 5, attempt: 7))
    }

    // MARK: - Flapping

    func testTheFlapLimitStopsALoopThatEveryReconnectUsedToReset() {
        XCTAssertEqual(decide(recentEnds: Policy.flapLimit - 1), .retry(after: 1.5, attempt: 0))
        XCTAssertEqual(decide(recentEnds: Policy.flapLimit), .giveUp(notice: Policy.flapNotice))
        XCTAssertEqual(decide(presence: .locked, recentEnds: Policy.flapLimit),
                       .parkUntilForeground(notice: Policy.parkedWhileLockedNotice))
        XCTAssertEqual(decide(presence: .background, recentEnds: Policy.flapLimit),
                       .parkUntilForeground(notice: Policy.parkedInBackgroundNotice))
    }

    func testTheFlapRowComesBeforeTheBudget() {
        XCTAssertEqual(decide(attempt: 99, recentEnds: Policy.flapLimit),
                       .giveUp(notice: Policy.flapNotice))
    }

    // MARK: - Back in front

    func testComingBackToTheFrontResumesAParkedLadderOnlyFromAStoppedCamera() {
        XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: true, cameraPhase: .stopped),
                       .resumeLadder)
        XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: true, cameraPhase: nil),
                       .resumeLadder)
        XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: true, cameraPhase: .stopping),
                       .resumeLadder)
    }

    /// A pause is waited out, never started out of (`StreamPausePolicy`).
    func testAParkedButPausedCameraWaitsForTheSDK() {
        XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: true, cameraPhase: .paused),
                       .awaitSDKResume)
        for phase: CameraStreamStatePolicy.StreamState in [.starting, .waitingForDevice, .streaming] {
            XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: true, cameraPhase: phase),
                           .awaitSDKResume, "\(phase)")
        }
    }

    func testNothingResumesForAStoppedCameraOrWithoutAPark() {
        XCTAssertEqual(Policy.onForeground(parked: true, streamingIntended: false, cameraPhase: .stopped),
                       .nothing)
        XCTAssertEqual(Policy.onForeground(parked: false, streamingIntended: true, cameraPhase: .stopped),
                       .nothing)
        XCTAssertEqual(Policy.onForeground(parked: false, streamingIntended: true, cameraPhase: .paused),
                       .nothing)
    }

    // MARK: - The stall detector's handoff

    func testOnlyARebuildThatThrewIsHandedToTheLadder() {
        XCTAssertTrue(Policy.handsOffToLadder(after: .failed, streamingIntended: true))
        XCTAssertFalse(Policy.handsOffToLadder(after: .failed, streamingIntended: false))
        XCTAssertFalse(Policy.handsOffToLadder(after: .noFrame, streamingIntended: true))
        XCTAssertFalse(Policy.handsOffToLadder(after: .recovered, streamingIntended: true))
        XCTAssertFalse(Policy.handsOffToLadder(after: nil, streamingIntended: true))
    }

    // MARK: - Presence

    func testPresenceFromTheAppsSignals() {
        XCTAssertEqual(Policy.presence(scenePhase: .active, protectedDataAvailable: true,
                                       previous: .background), .foreground)
        XCTAssertEqual(Policy.presence(scenePhase: .background, protectedDataAvailable: true,
                                       previous: .foreground), .background)
        XCTAssertEqual(Policy.presence(scenePhase: .background, protectedDataAvailable: false,
                                       previous: .background), .locked)
        // Protected data gone outranks the phase, whatever order the two arrive in.
        XCTAssertEqual(Policy.presence(scenePhase: .active, protectedDataAvailable: false,
                                       previous: .foreground), .locked)
    }

    func testTheTransitionWindowLeavesPresenceWhereItWas() {
        XCTAssertEqual(Policy.presence(scenePhase: .inactive, protectedDataAvailable: true,
                                       previous: .foreground), .foreground)
        XCTAssertEqual(Policy.presence(scenePhase: .inactive, protectedDataAvailable: true,
                                       previous: .background), .background)
        // Unlocked but not yet in front.
        XCTAssertEqual(Policy.presence(scenePhase: .inactive, protectedDataAvailable: true,
                                       previous: .locked), .background)
    }

    @MainActor
    func testTheCameraHearsThePresenceOnlyWhenItChanges() {
        let backend = MockCameraBackend()
        let camera = CameraService(backend: backend, phoneCamera: MockPhoneCamera())
        camera.notePresence(scenePhase: .inactive)
        camera.notePresence(scenePhase: .background)
        camera.notePresence(scenePhase: .background)
        camera.notePresence(protectedDataAvailable: false)
        camera.notePresence(protectedDataAvailable: true)
        camera.notePresence(scenePhase: .inactive)
        camera.notePresence(scenePhase: .active)
        XCTAssertEqual(backend.presences, [.background, .locked, .background, .foreground])
        XCTAssertEqual(camera.presence, .foreground)
    }

    // MARK: - Copy

    func testTheParkedNoticeLeadsWithWhereThePhoneWasAndKeepsTheReason() {
        XCTAssertEqual(Policy.parkedNotice(presence: .locked), Policy.parkedWhileLockedNotice)
        XCTAssertEqual(Policy.parkedNotice(presence: .background), Policy.parkedInBackgroundNotice)
        let withReason = Policy.parkedNotice(presence: .locked, reason: "Too hot.")
        XCTAssertTrue(withReason.hasPrefix(Policy.parkedWhileLockedNotice))
        XCTAssertTrue(withReason.hasSuffix("Too hot."))
    }

    /// Rendered strings carry no plan letters, no codec names and no internal vocabulary.
    func testNoticeCopyCarriesNoPlanLettersOrCodecNames() throws {
        let notices = [Policy.flapNotice, Policy.parkedWhileLockedNotice, Policy.parkedInBackgroundNotice,
                       Policy.parkedNotice(presence: .locked, reason: "Too hot.")]
        let planLetters = try NSRegularExpression(pattern: #"\b(Plan\s+)?[A-Z]{2,3}\d*\b"#)
        for notice in notices {
            XCTAssertFalse(notice.isEmpty)
            let range = NSRange(notice.startIndex..., in: notice)
            XCTAssertNil(planLetters.firstMatch(in: notice, range: range), notice)
            for word in ["plan", "hvc1", "hevc", "h264", "raw", "codec", "ladder", "rung", "sdk"] {
                XCTAssertFalse(notice.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                                .contains(Substring(word)), "\(word) in \(notice)")
            }
        }
    }

    // MARK: - Source guard

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The backend cannot run here (`Wearables` traps in a test process), so the handoff is held
    /// in place by its text: the stall detector's `.linkStalled` arm reads the rebuild's outcome
    /// and asks the table whether to hand the end to the ladder. Refactor it away and this fails.
    func testTheStallDetectorStillHandsAFailedRecoveryToTheLadder() throws {
        let path = "OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift"
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        let arm = try XCTUnwrap(source.range(of: "case .linkStalled:"))
        let armEnd = try XCTUnwrap(source.range(of: "private func stopStallDetection()",
                                                range: arm.upperBound..<source.endIndex))
        let body = String(source[arm.upperBound..<armEnd.lowerBound])
        XCTAssertTrue(body.contains("let outcome = await self.recoverFromLinkStall()"))
        XCTAssertTrue(body.contains("StreamEndRecoveryPolicy.handsOffToLadder("))
        XCTAssertTrue(body.contains("after: outcome"))
        XCTAssertTrue(body.contains("streamEndedWhileWanted(trigger: .stallRecoveryFailed)"))
        // After the flag is cleared, never before: otherwise the table would defer to an owner
        // that has already let go.
        let cleared = try XCTUnwrap(body.range(of: "self.isRecoveringFromStall = false"))
        let handoff = try XCTUnwrap(body.range(of: "StreamEndRecoveryPolicy.handsOffToLadder("))
        XCTAssertLessThan(cleared.lowerBound, handoff.lowerBound)
        // And the one entry point asks the new table.
        XCTAssertTrue(source.contains("StreamEndRecoveryPolicy.decide("))
        XCTAssertFalse(source.contains("StreamReconnectPolicy.next("))
    }
}

#endif
