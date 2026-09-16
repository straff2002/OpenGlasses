import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR3 — the launch gate, input by input.
///
/// Every case here is a sentence a blind wearer either hears or does not, so the assertions are
/// about *which* reason comes back as much as about start-versus-skip: two different problems
/// reported with the same words is the same dead end as reporting neither.
final class BlindAssistantLaunchPolicyTests: XCTestCase {

    private typealias Policy = BlindAssistantLaunchPolicy

    /// Everything satisfied. Each test below breaks exactly one input.
    private func ready(_ mutate: (inout Policy.Inputs) -> Void = { _ in }) -> Policy.Inputs {
        var inputs = Policy.Inputs(settingEnabled: true)
        mutate(&inputs)
        return inputs
    }

    // MARK: - The start

    func testEverythingReadyStarts() {
        XCTAssertEqual(Policy.decide(ready()), .start(.init(audioOnly: nil)))
    }

    func testFullStartSaysNothingOfItsOwn() {
        // The session-usable cue owns this moment (PR2). A second voice saying the same thing is
        // the failure that plan exists to prevent.
        XCTAssertNil(Policy.decide(ready()).announcement)
    }

    // MARK: - The skips, in the order they are evaluated

    func testSettingOffIsTheFirstGateAndIsSilent() {
        let decision = Policy.decide(Policy.Inputs(settingEnabled: false,
                                                   providerConfigured: false,
                                                   microphoneGranted: false))
        XCTAssertEqual(decision, .skip(.settingOff))
        XCTAssertNil(decision.announcement, "A wearer who never asked for this must not be told about it")
    }

    func testOnboardingNotFinished() {
        let decision = Policy.decide(ready { $0.isPastOnboarding = false })
        XCTAssertEqual(decision, .skip(.setupNotFinished))
        XCTAssertEqual(decision.announcement, "Not starting the assistant: setup isn't finished yet.")
    }

    func testAnotherPresetSelected() {
        let decision = Policy.decide(ready { $0.selectedPresetID = "museum" })
        XCTAssertEqual(decision, .skip(.differentAssistantSelected))
        XCTAssertEqual(decision.announcement,
                       "Not starting the assistant: Blind Assistant isn't the selected live mode.")
    }

    func testSessionAlreadyRunningIsSilent() {
        let decision = Policy.decide(ready { $0.sessionAlreadyActive = true })
        XCTAssertEqual(decision, .skip(.sessionAlreadyRunning))
        XCTAssertNil(decision.announcement)
    }

    func testStoppedByUserIsSilent() {
        let decision = Policy.decide(ready { $0.stoppedByUserThisForeground = true })
        XCTAssertEqual(decision, .skip(.stoppedByUser))
        XCTAssertNil(decision.announcement, "They stopped it on purpose; saying so on every return is noise")
    }

    func testSilentModeIsSilent() {
        let decision = Policy.decide(ready { $0.silentMode = true })
        XCTAssertEqual(decision, .skip(.silentMode))
        XCTAssertNil(decision.announcement, "Speaking the reason would contradict the setting being reported")
        XCTAssertFalse(decision.summary.isEmpty, "Settings still has to be able to show it")
    }

    func testMicrophonePermissionOff() {
        let decision = Policy.decide(ready { $0.microphoneGranted = false })
        XCTAssertEqual(decision, .skip(.microphonePermissionOff))
        XCTAssertEqual(decision.announcement,
                       "Not starting the assistant: microphone permission is off. Turn it on in iOS Settings, under OpenGlasses.")
    }

    func testSpeechPermissionOff() {
        let decision = Policy.decide(ready { $0.speechRecognitionGranted = false })
        XCTAssertEqual(decision, .skip(.speechPermissionOff))
        XCTAssertNotNil(decision.announcement)
    }

    func testProviderNotConfiguredNamesTheProvider() {
        let gemini = Policy.decide(ready { $0.providerConfigured = false })
        XCTAssertEqual(gemini, .skip(.providerNotConfigured(.gemini)))
        XCTAssertEqual(gemini.announcement,
                       "Not starting the assistant: there's no Gemini API key yet. Add one in OpenGlasses settings.")

        let openAI = Policy.decide(ready {
            $0.providerConfigured = false
            $0.provider = .openAIRealtime
        })
        XCTAssertEqual(openAI, .skip(.providerNotConfigured(.openAIRealtime)))
        XCTAssertEqual(openAI.announcement,
                       "Not starting the assistant: there's no OpenAI API key yet. Add one in OpenGlasses settings.")
    }

    // MARK: - Audio-only starts

    func testMissingCameraPermissionStartsAudioOnlyAndSaysSo() {
        let decision = Policy.decide(ready { $0.cameraGranted = false })
        XCTAssertEqual(decision, .start(.init(audioOnly: .cameraPermissionOff)))
        XCTAssertEqual(decision.announcement,
                       "Starting the assistant. Camera access is off, so it can hear you but not see.")
    }

    func testNoGlassesStartsAudioOnlyAndSaysSo() {
        let decision = Policy.decide(ready { $0.glassesReady = false })
        XCTAssertEqual(decision, .start(.init(audioOnly: .noGlasses)))
        XCTAssertEqual(decision.announcement,
                       "Starting the assistant without the glasses. It can hear you, but there's no camera.")
    }

    func testCameraPermissionIsReportedBeforeMissingGlasses() {
        // The fixable one wins: a phone whose camera permission is off would otherwise be reported
        // as a glasses problem the wearer can do nothing about.
        let decision = Policy.decide(ready {
            $0.cameraGranted = false
            $0.glassesReady = false
        })
        XCTAssertEqual(decision, .start(.init(audioOnly: .cameraPermissionOff)))
    }

    // MARK: - Ordering

    func testEveryBlockingInputIsReportedWhenItIsTheOnlyOne() {
        // One case per skip that a *single* broken input can produce, so a reordering that hides
        // one behind another fails here rather than in a wearer's ear.
        let cases: [(Policy.SkipReason, (inout Policy.Inputs) -> Void)] = [
            (.setupNotFinished, { $0.isPastOnboarding = false }),
            (.differentAssistantSelected, { $0.selectedPresetID = "standard" }),
            (.sessionAlreadyRunning, { $0.sessionAlreadyActive = true }),
            (.stoppedByUser, { $0.stoppedByUserThisForeground = true }),
            (.silentMode, { $0.silentMode = true }),
            (.microphonePermissionOff, { $0.microphoneGranted = false }),
            (.speechPermissionOff, { $0.speechRecognitionGranted = false }),
            (.providerNotConfigured(.gemini), { $0.providerConfigured = false }),
        ]
        for (expected, mutate) in cases {
            XCTAssertEqual(Policy.decide(ready(mutate)), .skip(expected))
        }
    }

    func testOnboardingOutranksEveryLaterProblem() {
        let decision = Policy.decide(ready {
            $0.isPastOnboarding = false
            $0.microphoneGranted = false
            $0.providerConfigured = false
            $0.selectedPresetID = "museum"
        })
        XCTAssertEqual(decision, .skip(.setupNotFinished))
    }

    func testStopLatchOutranksPermissionAndProviderProblems() {
        let decision = Policy.decide(ready {
            $0.stoppedByUserThisForeground = true
            $0.microphoneGranted = false
        })
        XCTAssertEqual(decision, .skip(.stoppedByUser),
                       "Nothing to fix: the wearer asked for it to stay down")
    }

    // MARK: - Copy

    func testEverySkipHasASummaryAndOnlySpokenOnesHaveALine() {
        let all: [Policy.SkipReason] = [
            .settingOff, .setupNotFinished, .differentAssistantSelected, .sessionAlreadyRunning,
            .stoppedByUser, .silentMode, .microphonePermissionOff, .speechPermissionOff,
            .providerNotConfigured(.gemini), .providerNotConfigured(.openAIRealtime),
        ]
        for reason in all {
            XCTAssertFalse(reason.summary.isEmpty, "\(reason) has nothing to show")
            XCTAssertEqual(reason.spokenReason != nil, reason.isSpoken, "\(reason)")
            if let line = reason.spokenReason {
                XCTAssertTrue(line.hasPrefix("Not starting the assistant: "), line)
            }
        }
    }

    func testSettingsSummaryIsNeverEmptyForAnyDecision() {
        XCTAssertFalse(Policy.decide(ready()).summary.isEmpty)
        XCTAssertFalse(Policy.decide(ready { $0.silentMode = true }).summary.isEmpty)
        XCTAssertFalse(Policy.decide(ready { $0.cameraGranted = false }).summary.isEmpty)
    }

    func testPresetIdentityIsTheSharedContractRatherThanALiteral() {
        XCTAssertEqual(Policy.decide(ready { $0.selectedPresetID = BlindAssistanceContract.presetID }),
                       .start(.init(audioOnly: nil)))
    }
}
