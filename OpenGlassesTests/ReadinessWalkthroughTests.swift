import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR8 — the readiness walk-through: the table, and the runner's obligations.
///
/// Everything here runs against a fake probe. That is the point of the split: the interesting
/// states — a connected camera with no picture, a healthy listener whose test line was talked
/// over, a wearer with no glasses at all — cannot be produced in a process that has neither
/// glasses nor an audio route, and a check that could only be exercised on hardware is a check
/// nobody exercises.
@MainActor
final class ReadinessWalkthroughTests: XCTestCase {

    // MARK: - Fakes

    /// Scripted evidence, plus the two counters that prove the release rule.
    private final class FakeProbe: ReadinessStepProbing {
        var evidenceByStep: [ReadinessWalkthrough.Step: ReadinessWalkthrough.Evidence] = [:]
        /// Steps whose evidence was gathered, in order. A retry appends again.
        private(set) var gathered: [ReadinessWalkthrough.Step] = []
        private(set) var released: [ReadinessWalkthrough.Step] = []
        /// Stands in for the camera claim and the listener: incremented on acquire, decremented on
        /// release. Anything but zero at the end of a run is a leak.
        private(set) var outstandingCameraClaims = 0
        private(set) var outstandingListeners = 0
        private(set) var peakCameraClaims = 0

        func evidence(for step: ReadinessWalkthrough.Step) async
            -> ReadinessWalkthrough.Evidence {
            gathered.append(step)
            switch step {
            case .cameraEvidence, .readingRequest:
                outstandingCameraClaims += 1
                peakCameraClaims = max(peakCameraClaims, outstandingCameraClaims)
            case .spokenExchange:
                outstandingListeners += 1
            case .registration, .permissions:
                break
            }
            return evidenceByStep[step] ?? .launch(BlindAssistantLaunchPolicy.Inputs())
        }

        func release(after step: ReadinessWalkthrough.Step) async {
            released.append(step)
            switch step {
            case .cameraEvidence, .readingRequest:
                outstandingCameraClaims -= 1
            case .spokenExchange:
                outstandingListeners -= 1
            case .registration, .permissions:
                break
            }
        }
    }

    /// A probe scripted to pass every step, so a test only has to state the one it is changing.
    private func passingProbe() -> FakeProbe {
        let probe = FakeProbe()
        probe.evidenceByStep = [
            .registration: .launch(BlindAssistantLaunchPolicy.Inputs()),
            .permissions: .launch(BlindAssistantLaunchPolicy.Inputs()),
            .cameraEvidence: .camera(.init(streamClaimed: true, readiness: freshCamera())),
            .spokenExchange: .spokenExchange(.init(listener: .healthy, speech: .completed)),
            .readingRequest: .reading(.init(source: .camera, quality: .usable)),
        ]
        return probe
    }

    private func freshCamera() -> CameraReadiness {
        CameraReadiness(phase: .ready, frameAge: 0.1, session: 1, userWantsStream: true)
    }

    private func makeRunner(_ probe: FakeProbe,
                            spoken: SpokenLines = SpokenLines()) -> ReadinessWalkthroughRunner {
        ReadinessWalkthroughRunner(probe: probe) { line in spoken.lines.append(line) }
    }

    /// A reference box so the runner's `speak` closure can record without capturing a `var`.
    private final class SpokenLines {
        var lines: [String] = []
    }

    // MARK: - Every step passes

    func testARunWhereEverythingPassesRunsAllFiveStepsInOrder() async {
        let probe = passingProbe()
        let spoken = SpokenLines()
        let runner = makeRunner(probe, spoken: spoken)

        await runner.run()

        XCTAssertEqual(runner.results.map(\.step), ReadinessWalkthrough.Step.allCases)
        XCTAssertTrue(runner.results.allSatisfy { $0.verdict.isPassed },
                      runner.results.map { "\($0.step): \($0.verdict.token)" }.joined(separator: ", "))
        XCTAssertTrue(runner.completedCleanly)
        XCTAssertEqual(runner.summary, "All five checks passed. The assistant is ready.")
        // One status per step, plus the closing summary.
        XCTAssertEqual(spoken.lines.count, ReadinessWalkthrough.Step.allCases.count + 1)
        XCTAssertEqual(spoken.lines.last, runner.summary)
    }

    func testEachPassingStepSpeaksItsOwnExactStatus() async {
        let spoken = SpokenLines()
        let runner = makeRunner(passingProbe(), spoken: spoken)

        await runner.run()

        XCTAssertEqual(Array(spoken.lines.dropLast()), [
            "Glasses. Connected and reachable.",
            "Permissions. Microphone, speech recognition and camera are all on.",
            "Camera picture. A fresh picture arrived from the glasses.",
            "Microphone and voice. Listening is running, and you just heard a test line.",
            "Reading something. The photo is sharp enough to read fine print.",
        ])
    }

    // MARK: - The camera rule

    /// The rule the whole step exists for: a stream that is up, and an SDK that says connected,
    /// are not a picture.
    func testAConnectedCameraWithNoFreshFrameFailsTheCameraStep() async {
        let probe = passingProbe()
        probe.evidenceByStep[.cameraEvidence] = .camera(.init(
            streamClaimed: true,
            readiness: CameraReadiness(phase: .awaitingFirstFrame, frameAge: nil,
                                       session: 1, userWantsStream: true)))
        let runner = makeRunner(probe)

        await runner.run()

        let result = try? XCTUnwrap(runner.results.first { $0.step == .cameraEvidence })
        XCTAssertEqual(result?.verdict.token, "failed")
        XCTAssertTrue(result?.spokenStatus.contains("no fresh picture arrived") == true,
                      result?.spokenStatus ?? "no status")
        XCTAssertNotNil(result?.nextInstruction)
        XCTAssertEqual(result?.retryAvailable, true)
    }

    /// A picture that arrived, and then stopped arriving, is also not evidence.
    func testAStalePictureFailsTheCameraStep() async {
        let probe = passingProbe()
        probe.evidenceByStep[.cameraEvidence] = .camera(.init(
            streamClaimed: true,
            readiness: CameraReadiness(phase: .ready,
                                       frameAge: CameraReadiness.evidenceMaxAge + 5,
                                       session: 1, userWantsStream: true)))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(runner.results.last?.step, .cameraEvidence)
        XCTAssertTrue(runner.results.last?.verdict.isFailed == true)
    }

    // MARK: - The spoken-exchange rule

    /// Listening is fine and the wearer heard nothing. The two facts are separate, and the step
    /// needs both.
    func testAHealthyListenerWithAnInterruptedTestLineFailsWithARetry() async {
        let probe = passingProbe()
        probe.evidenceByStep[.spokenExchange] = .spokenExchange(
            .init(listener: .healthy, speech: .interrupted(by: .bargeIn)))
        let runner = makeRunner(probe)

        await runner.run()

        let result = runner.results.last
        XCTAssertEqual(result?.step, .spokenExchange)
        XCTAssertEqual(result?.verdict.token, "failed")
        XCTAssertEqual(result?.spokenStatus,
                       "Microphone and voice. The test line was cut off because something was heard on the microphone.")
        XCTAssertEqual(result?.nextInstruction, "Stay quiet for a moment and try again.")
        XCTAssertEqual(result?.retryAvailable, true)
    }

    func testABrokenListenerFailsBeforeAnythingIsSpoken() async {
        let probe = passingProbe()
        probe.evidenceByStep[.spokenExchange] = .spokenExchange(
            .init(listener: .rebuild(.recognitionEnded)))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(runner.results.last?.spokenStatus,
                       "Microphone and voice. The microphone is open, but speech recognition has stopped.")
        XCTAssertEqual(runner.results.last?.nextInstruction, "Try again — that restarts listening.")
    }

    func testAStartFreshListenerIsAcceptedTheSameAsAHealthyOne() async {
        let probe = passingProbe()
        probe.evidenceByStep[.spokenExchange] = .spokenExchange(
            .init(listener: .startFresh, speech: .completed))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertTrue(runner.completedCleanly)
    }

    // MARK: - Permissions

    func testARefusedMicrophoneFailsWithTheLaunchPolicysOwnSentenceAndTheSettingsRoute() async {
        let probe = passingProbe()
        probe.evidenceByStep[.permissions] = .launch(
            BlindAssistantLaunchPolicy.Inputs(microphoneGranted: false))
        let runner = makeRunner(probe)

        await runner.run()

        let result = runner.results.last
        XCTAssertEqual(result?.step, .permissions)
        // The same sentence the launch decision uses, so the two surfaces cannot drift.
        XCTAssertTrue(result?.spokenStatus.hasSuffix(
            BlindAssistantLaunchPolicy.SkipReason.microphonePermissionOff.summary) == true,
                      result?.spokenStatus ?? "")
        XCTAssertEqual(result?.nextInstruction, ReadinessWalkthrough.openSettingsInstruction)
    }

    func testARefusedSpeechPermissionFailsToo() async {
        let probe = passingProbe()
        probe.evidenceByStep[.permissions] = .launch(
            BlindAssistantLaunchPolicy.Inputs(speechRecognitionGranted: false))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(runner.results.last?.step, .permissions)
        XCTAssertTrue(runner.results.last?.verdict.isFailed == true)
    }

    // MARK: - The audio-only path

    /// No glasses is not a failure. It is a different, legitimate setup, and the check has to say
    /// so rather than telling a wearer their assistant is broken.
    func testTheAudioOnlyPathPassesRegistrationAndCameraWithANoteAndSkipsReading() async {
        let probe = FakeProbe()
        let audioOnly = BlindAssistantLaunchPolicy.Inputs(glassesReady: false)
        probe.evidenceByStep = [
            .registration: .launch(audioOnly),
            .permissions: .launch(audioOnly),
            .cameraEvidence: .camera(.init(audioOnly: .noGlasses, streamClaimed: false)),
            .spokenExchange: .spokenExchange(.init(listener: .healthy, speech: .completed)),
            .readingRequest: .reading(.init(audioOnly: .noGlasses)),
        ]
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(runner.results.count, 5)
        XCTAssertTrue(runner.completedCleanly, "an audio-only setup must not be reported as broken")

        let registration = runner.results[0]
        XCTAssertEqual(registration.verdict.token, "passed-with-note")
        XCTAssertTrue(registration.spokenStatus.lowercased().contains("audio-only"), registration.spokenStatus)

        let camera = runner.results[2]
        XCTAssertEqual(camera.verdict.token, "passed-with-note")
        XCTAssertTrue(camera.spokenStatus.lowercased().contains("audio-only"), camera.spokenStatus)

        XCTAssertTrue(runner.results[4].verdict.isSkipped)
        XCTAssertEqual(runner.summary,
                       "The checks passed, with notes. This is an audio-only setup.")
    }

    func testCameraPermissionOffAlsoPassesWithTheAudioOnlyNote() async {
        let probe = passingProbe()
        probe.evidenceByStep[.permissions] = .launch(
            BlindAssistantLaunchPolicy.Inputs(cameraGranted: false))
        probe.evidenceByStep[.cameraEvidence] = .camera(
            .init(audioOnly: .cameraPermissionOff, streamClaimed: false))
        probe.evidenceByStep[.readingRequest] = .reading(.init(audioOnly: .cameraPermissionOff))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(runner.results[1].verdict.token, "passed-with-note")
        XCTAssertTrue(runner.completedCleanly)
    }

    // MARK: - Reading

    func testABlurryPhotoFailsWithTheRepositionInstructionFromTheCapturePolicy() async {
        let probe = passingProbe()
        probe.evidenceByStep[.readingRequest] = .reading(.init(source: .camera, quality: .tooBlurry))
        let runner = makeRunner(probe)

        await runner.run()

        let result = runner.results.last
        XCTAssertEqual(result?.step, .readingRequest)
        XCTAssertEqual(result?.verdict.token, "failed")
        // The wearer's sentence is the capture policy's own, not a second copy of it.
        XCTAssertEqual(result?.nextInstruction,
                       ReadingCaptureOutcome.spokenInstruction(for: .tooBlurry,
                                                               isReadingRequest: true))
    }

    func testNoPictureAtAllReportsTheChokepointsOwnReason() async {
        let probe = passingProbe()
        probe.evidenceByStep[.readingRequest] = .reading(.init(unavailable: .noFreshView))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertTrue(runner.results.last?.spokenStatus
            .contains(ReadingCaptureOutcome.spokenUnavailable(.noFreshView)) == true,
                      runner.results.last?.spokenStatus ?? "")
    }

    /// A fixture pass is a pass, and it says it was a fixture. It is never reported as a camera
    /// pass, because nothing about a rendered page proves a wearer's camera works.
    func testAFixturePassSaysItWasAFixture() async {
        let probe = passingProbe()
        probe.evidenceByStep[.readingRequest] = .reading(.init(source: .fixture, quality: .usable))
        let runner = makeRunner(probe)

        await runner.run()

        let result = runner.results.last
        XCTAssertEqual(result?.verdict.token, "passed-with-note")
        XCTAssertTrue(result?.spokenStatus.contains("stored test photo") == true,
                      result?.spokenStatus ?? "")
        XCTAssertTrue(result?.spokenStatus.contains("doesn't prove your camera does") == true,
                      result?.spokenStatus ?? "")
    }

    /// The fixture the simulator path measures has to actually clear the reading thresholds, or
    /// the documented pass would be a documented failure.
    func testTheRenderedFixtureMeasuresAsUsable() {
        XCTAssertEqual(ReadinessReadingFixture.measuredQuality(), .usable)
    }

    // MARK: - Stopping at the first failure

    func testAFailureStopsTheSequenceAndTheFixIsSpoken() async {
        let probe = passingProbe()
        probe.evidenceByStep[.permissions] = .launch(
            BlindAssistantLaunchPolicy.Inputs(microphoneGranted: false))
        let spoken = SpokenLines()
        let runner = makeRunner(probe, spoken: spoken)

        await runner.run()

        // Two steps ran; the three after the failure did not.
        XCTAssertEqual(runner.results.map(\.step), [.registration, .permissions])
        XCTAssertEqual(probe.gathered, [.registration, .permissions])
        XCTAssertFalse(runner.completedCleanly)
        // The failing status, then the fix, then the summary — the instruction is spoken, not only
        // rendered, because the wearer this is for is not reading it.
        XCTAssertEqual(spoken.lines.suffix(2).first, ReadinessWalkthrough.openSettingsInstruction)
        XCTAssertTrue(runner.summary.hasPrefix("Check stopped at Permissions."), runner.summary)
    }

    // MARK: - Retry

    func testARetryReRunsThatStepAndCarriesOnFromThere() async {
        let probe = passingProbe()
        probe.evidenceByStep[.permissions] = .launch(
            BlindAssistantLaunchPolicy.Inputs(microphoneGranted: false))
        let runner = makeRunner(probe)
        await runner.run()
        XCTAssertEqual(runner.results.count, 2)

        // The wearer granted the permission in iOS Settings and came back.
        probe.evidenceByStep[.permissions] = .launch(BlindAssistantLaunchPolicy.Inputs())
        await runner.retry(.permissions)

        XCTAssertEqual(runner.results.map(\.step), ReadinessWalkthrough.Step.allCases)
        XCTAssertTrue(runner.completedCleanly)
        // Registration was not re-run: a retry costs one step, not five.
        XCTAssertEqual(probe.gathered.filter { $0 == .registration }.count, 1)
        XCTAssertEqual(probe.gathered.filter { $0 == .permissions }.count, 2)
    }

    // MARK: - Resources

    /// Plan EW's rule, enforced by the runner rather than trusted to each probe: every step
    /// releases what it took, on the failing path as well as the passing one.
    func testEveryStepReleasesWhatItAcquiredIncludingTheFailingOne() async {
        let probe = passingProbe()
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertEqual(probe.released, probe.gathered,
                       "a step gathered evidence without a matching release")
        XCTAssertEqual(probe.outstandingCameraClaims, 0, "the camera claim was left held")
        XCTAssertEqual(probe.outstandingListeners, 0, "something was left listening")
        XCTAssertEqual(probe.peakCameraClaims, 1,
                       "two camera-claiming steps overlapped — one must be given back before the next")
    }

    func testAFailingStepStillReleasesItsResources() async {
        let probe = passingProbe()
        probe.evidenceByStep[.cameraEvidence] = .camera(.init(
            streamClaimed: true,
            readiness: CameraReadiness(phase: .framesUnavailable, frameAge: nil,
                                       session: 1, userWantsStream: true)))
        let runner = makeRunner(probe)

        await runner.run()

        XCTAssertTrue(runner.results.last?.verdict.isFailed == true)
        XCTAssertEqual(probe.released.last, .cameraEvidence)
        XCTAssertEqual(probe.outstandingCameraClaims, 0)
    }

    // MARK: - Focus

    /// Focus is set *before* the status is spoken, so a wearer reaching for the row while it is
    /// being read finds it under their finger. Recording at the speak point is exactly what the
    /// view sees.
    func testFocusMovesToEachStepBeforeItsStatusIsSpoken() async {
        let probe = passingProbe()
        let observed = ObservedFocus()
        var runner: ReadinessWalkthroughRunner!
        runner = ReadinessWalkthroughRunner(probe: probe) { _ in
            if let target = runner.focusTarget, observed.steps.last != target {
                observed.steps.append(target)
            }
        }

        await runner.run()

        XCTAssertEqual(observed.steps, ReadinessWalkthrough.Step.allCases)
    }

    private final class ObservedFocus {
        var steps: [ReadinessWalkthrough.Step] = []
    }

    func testFocusTargetTracksTheStepJustCompleted() async {
        let probe = passingProbe()
        probe.evidenceByStep[.cameraEvidence] = .camera(.init(
            streamClaimed: false))
        let runner = makeRunner(probe)

        await runner.run()

        // The run stopped at the camera step, so that is where a wearer's focus should be.
        XCTAssertEqual(runner.focusTarget, .cameraEvidence)
        XCTAssertEqual(runner.results.last?.step, .cameraEvidence)
    }

    // MARK: - Table-level

    func testMismatchedEvidenceFailsTheStepRatherThanTrapping() {
        let result = ReadinessWalkthrough.result(
            for: .cameraEvidence,
            evidence: .launch(BlindAssistantLaunchPolicy.Inputs()))
        XCTAssertTrue(result.verdict.isFailed)
        XCTAssertEqual(result.retryAvailable, true)
    }

    func testTheStepOrderIsTheDocumentedOne() {
        XCTAssertEqual(ReadinessWalkthrough.Step.allCases,
                       [.registration, .permissions, .cameraEvidence, .spokenExchange, .readingRequest])
    }

    func testEveryStepHasATitleAndAPurpose() {
        for step in ReadinessWalkthrough.Step.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step) has no title")
            XCTAssertFalse(step.purpose.isEmpty, "\(step) has no purpose")
        }
    }
}
