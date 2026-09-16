import Foundation

/// Plan FF P1/PR8 — the guided readiness check, as a decision table.
///
/// # Why this exists
///
/// Every part of "is the assistant actually going to work?" already has an owner: the launch
/// policy knows about registration and permissions, `CameraReadiness` knows what counts as a
/// picture, `ListenerHealthPolicy` knows whether the microphone graph is alive, the delivery
/// outcome knows whether a spoken line reached its end, and the capture quality report knows
/// whether a still is good enough to read from. What did not exist is a way for a wearer to ask
/// all five, in order, and be told out loud which one is the problem and what to do about it.
///
/// So this adds no new facts. It orders the existing ones and, for each, produces the three things
/// a wearer who cannot see the screen actually needs: **one spoken status**, **one next
/// instruction**, and **whether trying again is worth anything**.
///
/// # The rule that makes it worth running
///
/// A step passes on *evidence*, never on a component reporting that it exists. A connected SDK, a
/// running stream, an open socket and a `true` flag are all things this deliberately refuses to
/// accept: the camera step wants a decoded picture younger than `CameraReadiness.evidenceMaxAge`,
/// and the spoken-exchange step wants a `SpeechDeliveryOutcome.completed`, not a `speak()` that
/// returned.
///
/// Pure value logic — no camera, no audio, no clock. The acquiring and releasing lives in
/// `ReadinessWalkthroughRunner` and its probes, which is what makes the whole table testable in a
/// process that has neither.
enum ReadinessWalkthrough {

    // MARK: - Steps

    /// The five checks, in the order they are run. The order is the design: each one is a
    /// precondition of the next, so the first failure is the one worth reporting and everything
    /// after it would fail for a reason the wearer cannot act on yet.
    enum Step: String, CaseIterable, Identifiable, Equatable {
        /// Are the glasses paired and reachable — or is this deliberately an audio-only setup?
        case registration
        /// Microphone and speech recognition, which are required; camera, which is not.
        case permissions
        /// A decoded picture, recent enough to answer a question about what is in front of you.
        case cameraEvidence
        /// The microphone graph is alive, and a short spoken line reached its end.
        case spokenExchange
        /// One sharp still that clears the reading blur and darkness thresholds.
        case readingRequest

        var id: String { rawValue }

        /// The row title. Short, because VoiceOver reads it before the status every time.
        var title: String {
            switch self {
            case .registration: return "Glasses"
            case .permissions: return "Permissions"
            case .cameraEvidence: return "Camera picture"
            case .spokenExchange: return "Microphone and voice"
            case .readingRequest: return "Reading something"
            }
        }

        /// What this step is checking, for the row's accessibility hint.
        var purpose: String {
            switch self {
            case .registration: return "Checks the glasses are paired and reachable."
            case .permissions: return "Checks microphone, speech recognition and camera access."
            case .cameraEvidence: return "Starts the camera and waits for a fresh picture."
            case .spokenExchange: return "Checks the microphone is listening and you can hear a spoken line."
            case .readingRequest: return "Takes one sharp photo and checks it is clear enough to read."
            }
        }
    }

    // MARK: - Verdicts

    /// What one step concluded.
    ///
    /// `passed` carries an optional note rather than having a fourth case, because the notes it
    /// carries are all one thing: **this setup is audio-only and that is a legitimate way to use
    /// the assistant.** A wearer with no glasses, or who declined the camera, has not failed a
    /// readiness check — they have a working assistant that cannot see, and saying so is different
    /// from saying it is broken.
    enum Verdict: Equatable {
        case passed(note: String?)
        case failed(reason: String)
        case skipped(reason: String)

        var isPassed: Bool { if case .passed = self { return true }; return false }
        var isFailed: Bool { if case .failed = self { return true }; return false }
        var isSkipped: Bool { if case .skipped = self { return true }; return false }

        /// One fixed word for the row's accessibility value and for a log. Never the reason text.
        var token: String {
            switch self {
            case .passed(let note): return note == nil ? "passed" : "passed-with-note"
            case .failed: return "failed"
            case .skipped: return "skipped"
            }
        }
    }

    /// Everything one completed step produced.
    struct Result: Equatable, Identifiable {
        let step: Step
        let verdict: Verdict
        /// The single line spoken after the step, and the row's accessibility value.
        let spokenStatus: String
        /// The one thing to do next, or `nil` when nothing is owed. Never more than one — a list
        /// of possible fixes read aloud is a list nobody can hold in their head.
        let nextInstruction: String?
        /// Whether a Retry control is offered. Only where trying again could plausibly change the
        /// answer: a permission the wearer just granted in iOS Settings, a camera that needs a
        /// moment, a photo that needs holding still. Never for a state a retry cannot move.
        let retryAvailable: Bool

        var id: String { step.rawValue }

        /// What VoiceOver reads for the whole row, once: title, status, and the instruction if
        /// there is one. One element rather than three, so focus lands on a complete thought.
        var accessibilityLabel: String {
            var parts = [spokenStatus]
            if let nextInstruction { parts.append(nextInstruction) }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Evidence

    /// What a probe observed for one step. Gathering it is the runner's job; judging it is this
    /// file's.
    enum Evidence: Equatable {
        /// Registration and permissions both read the launch policy's own inputs, so the two
        /// surfaces cannot drift: a wearer who hears "microphone permission is off" at launch
        /// hears the same sentence here.
        case launch(BlindAssistantLaunchPolicy.Inputs)
        case camera(CameraEvidence)
        case spokenExchange(SpokenExchangeEvidence)
        case reading(ReadingEvidence)
    }

    /// What the camera step saw after it claimed the stream and waited.
    struct CameraEvidence: Equatable {
        /// Set when there is deliberately no camera to check — no glasses, or camera access off.
        /// A pass with a note, never a failure.
        var audioOnly: BlindAssistantLaunchPolicy.AudioOnlyReason?
        /// The walk-through's claim on the stream was taken. False when starting it threw.
        var streamClaimed: Bool
        /// What the camera reported at the end of the bounded wait. `nil` when the claim failed.
        var readiness: CameraReadiness?

        init(audioOnly: BlindAssistantLaunchPolicy.AudioOnlyReason? = nil,
             streamClaimed: Bool = true,
             readiness: CameraReadiness? = nil) {
            self.audioOnly = audioOnly
            self.streamClaimed = streamClaimed
            self.readiness = readiness
        }
    }

    /// What the microphone-and-voice step saw. Two separate facts on purpose: a listener that is
    /// healthy proves nothing about output, and a line that played proves nothing about input.
    struct SpokenExchangeEvidence: Equatable {
        var listener: ListenerHealthDecision
        /// `nil` when the listener decision meant the test line was never attempted.
        var speech: SpeechDeliveryOutcome?

        init(listener: ListenerHealthDecision, speech: SpeechDeliveryOutcome? = nil) {
            self.listener = listener
            self.speech = speech
        }
    }

    /// What the reading step saw.
    struct ReadingEvidence: Equatable {
        /// Where the measured still came from.
        enum Source: String, Equatable {
            /// A real capture through the privacy chokepoint, on real glasses.
            case camera
            /// A recorded fixture, because this build has no glasses camera to capture from — the
            /// simulator. Always a pass **with a note**: a fixture proves the measurement works,
            /// not that this wearer's camera does.
            case fixture
        }

        var source: Source
        /// Set when the step does not apply: an audio-only setup has nothing to read from.
        var audioOnly: BlindAssistantLaunchPolicy.AudioOnlyReason?
        /// The measured verdict. `nil` when no picture came back.
        var quality: CaptureQualityReport.Quality?
        /// The chokepoint's own reason when no picture came back at all.
        var unavailable: FilteredStillResult.Reason?

        init(source: Source = .camera,
             audioOnly: BlindAssistantLaunchPolicy.AudioOnlyReason? = nil,
             quality: CaptureQualityReport.Quality? = nil,
             unavailable: FilteredStillResult.Reason? = nil) {
            self.source = source
            self.audioOnly = audioOnly
            self.quality = quality
            self.unavailable = unavailable
        }
    }

    // MARK: - Copy

    /// The audio-only note, worded for where it appears. One sentence each, and each of them says
    /// what the assistant *can* still do — the first thing a wearer needs to know is not what is
    /// missing but whether they can carry on.
    static func audioOnlyNote(_ reason: BlindAssistantLaunchPolicy.AudioOnlyReason,
                              at step: Step) -> String {
        switch (reason, step) {
        case (.noGlasses, .registration):
            return "No glasses are connected, so this is an audio-only setup. The assistant can hear you and answer, but it can't see."
        case (.cameraPermissionOff, .registration):
            return "The glasses are connected. Camera access is off, so this is an audio-only setup."
        case (.noGlasses, _):
            return "Audio-only setup: there are no glasses, so there is no camera to check."
        case (.cameraPermissionOff, _):
            return "Audio-only setup: camera access is off, so there is no camera to check."
        }
    }

    /// Where a refused permission is actually granted. iOS asks once, so this is the only route.
    static let openSettingsInstruction =
        "Open iOS Settings, find OpenGlasses, and turn the permission on there. iOS only asks once."

    // MARK: - The table

    /// Judge one step's evidence.
    ///
    /// Mismatched evidence — the camera step handed a listener decision, say — is a programming
    /// error, and it fails the step rather than trapping: a readiness check that crashes is the
    /// one failure mode a wearer cannot report.
    static func result(for step: Step, evidence: Evidence) -> Result {
        switch (step, evidence) {
        case (.registration, .launch(let inputs)):
            return registrationResult(inputs)
        case (.permissions, .launch(let inputs)):
            return permissionsResult(inputs)
        case (.cameraEvidence, .camera(let camera)):
            return cameraResult(camera)
        case (.spokenExchange, .spokenExchange(let exchange)):
            return spokenExchangeResult(exchange)
        case (.readingRequest, .reading(let reading)):
            return readingResult(reading)
        default:
            return Result(step: step,
                          verdict: .failed(reason: "This check couldn't run."),
                          spokenStatus: "\(step.title). This check couldn't run.",
                          nextInstruction: "Close the check and start it again.",
                          retryAvailable: true)
        }
    }

    /// Whether the sequence continues past this result. It stops at the first failure — running on
    /// would produce failures caused by the first one, and a wearer would be handed four
    /// instructions where one is true.
    static func shouldContinue(after result: Result) -> Bool { !result.verdict.isFailed }

    /// The steps that follow `step`, in order. Used by a retry, which re-runs the failed step and
    /// then carries on rather than making the wearer start from the top.
    static func steps(from step: Step) -> [Step] {
        guard let index = Step.allCases.firstIndex(of: step) else { return [] }
        return Array(Step.allCases[index...])
    }

    // MARK: - Per-step rules

    private static func registrationResult(_ inputs: BlindAssistantLaunchPolicy.Inputs) -> Result {
        guard inputs.isPastOnboarding else {
            let reason = BlindAssistantLaunchPolicy.SkipReason.setupNotFinished.summary
            return Result(step: .registration,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Glasses. \(reason)",
                          nextInstruction: "Finish setup first, then run this check again.",
                          retryAvailable: true)
        }
        guard inputs.glassesReady else {
            let note = audioOnlyNote(.noGlasses, at: .registration)
            return Result(step: .registration,
                          verdict: .passed(note: note),
                          spokenStatus: "Glasses. \(note)",
                          nextInstruction: nil,
                          retryAvailable: true)
        }
        return Result(step: .registration,
                      verdict: .passed(note: nil),
                      spokenStatus: "Glasses. Connected and reachable.",
                      nextInstruction: nil,
                      retryAvailable: false)
    }

    private static func permissionsResult(_ inputs: BlindAssistantLaunchPolicy.Inputs) -> Result {
        // Microphone and speech recognition are both required, and both are reported with the
        // launch policy's own sentence so the wearer hears one wording for one condition.
        if !inputs.microphoneGranted {
            return permissionFailure(.microphonePermissionOff)
        }
        if !inputs.speechRecognitionGranted {
            return permissionFailure(.speechPermissionOff)
        }
        if !inputs.cameraGranted {
            let note = audioOnlyNote(.cameraPermissionOff, at: .permissions)
            return Result(step: .permissions,
                          verdict: .passed(note: note),
                          spokenStatus: "Permissions. Microphone and speech recognition are on. \(note)",
                          nextInstruction: nil,
                          retryAvailable: true)
        }
        return Result(step: .permissions,
                      verdict: .passed(note: nil),
                      spokenStatus: "Permissions. Microphone, speech recognition and camera are all on.",
                      nextInstruction: nil,
                      retryAvailable: false)
    }

    private static func permissionFailure(_ reason: BlindAssistantLaunchPolicy.SkipReason) -> Result {
        Result(step: .permissions,
               verdict: .failed(reason: reason.summary),
               spokenStatus: "Permissions. \(reason.summary)",
               nextInstruction: openSettingsInstruction,
               retryAvailable: true)
    }

    private static func cameraResult(_ camera: CameraEvidence) -> Result {
        if let audioOnly = camera.audioOnly {
            let note = audioOnlyNote(audioOnly, at: .cameraEvidence)
            return Result(step: .cameraEvidence,
                          verdict: .passed(note: note),
                          spokenStatus: "Camera picture. \(note)",
                          nextInstruction: nil,
                          retryAvailable: true)
        }
        guard camera.streamClaimed, let readiness = camera.readiness else {
            return Result(step: .cameraEvidence,
                          verdict: .failed(reason: "The camera didn't start."),
                          spokenStatus: "Camera picture. The camera didn't start.",
                          nextInstruction: "Put the glasses on, check they aren't folded, and try again.",
                          retryAvailable: true)
        }
        guard readiness.hasFreshVisualEvidence else {
            // The whole point of the step. A stream that is up, a socket that is open and an SDK
            // that reports connected all land here, because none of them is a picture.
            let reason = "The glasses are connected, but no fresh picture arrived. "
                + readiness.statusPhrase + "."
            return Result(step: .cameraEvidence,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Camera picture. \(reason)",
                          nextInstruction: readiness.controlHint
                              ?? "Put the glasses on and try again.",
                          retryAvailable: true)
        }
        return Result(step: .cameraEvidence,
                      verdict: .passed(note: nil),
                      spokenStatus: "Camera picture. A fresh picture arrived from the glasses.",
                      nextInstruction: nil,
                      retryAvailable: false)
    }

    private static func spokenExchangeResult(_ exchange: SpokenExchangeEvidence) -> Result {
        switch exchange.listener {
        case .healthy, .startFresh:
            break
        case .pausedDeliberately(let pause):
            let reason = pausedCopy(pause)
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Microphone and voice. \(reason)",
                          nextInstruction: "Stop the other feature that's using the microphone, then try again.",
                          retryAvailable: true)
        case .rebuild(let broken):
            let reason = brokenCopy(broken)
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Microphone and voice. \(reason)",
                          nextInstruction: "Try again — that restarts listening.",
                          retryAvailable: true)
        case .refuse(let refusal):
            let reason = refusalCopy(refusal)
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Microphone and voice. \(reason)",
                          nextInstruction: refusal == .noPermission
                              ? openSettingsInstruction
                              : "Turn Silent Mode off, then try again.",
                          retryAvailable: true)
        }

        guard let speech = exchange.speech else {
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: "The test line was never spoken."),
                          spokenStatus: "Microphone and voice. The test line was never spoken.",
                          nextInstruction: "Try again.",
                          retryAvailable: true)
        }

        switch speech {
        case .completed:
            return Result(step: .spokenExchange,
                          verdict: .passed(note: nil),
                          spokenStatus: "Microphone and voice. Listening is running, and you just heard a test line.",
                          nextInstruction: nil,
                          retryAvailable: false)
        case .interrupted(let by):
            let reason = interruptedCopy(by)
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Microphone and voice. \(reason)",
                          nextInstruction: "Stay quiet for a moment and try again.",
                          retryAvailable: true)
        case .suppressed(let why):
            let reason = suppressedCopy(why)
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Microphone and voice. \(reason)",
                          nextInstruction: suppressedInstruction(why),
                          retryAvailable: true)
        case .failed:
            // The reason string is an internal error summary; it is not read to the wearer.
            return Result(step: .spokenExchange,
                          verdict: .failed(reason: "The test line couldn't be played."),
                          spokenStatus: "Microphone and voice. The test line couldn't be played.",
                          nextInstruction: "Check the volume and the audio route, then try again.",
                          retryAvailable: true)
        }
    }

    private static func readingResult(_ reading: ReadingEvidence) -> Result {
        if let audioOnly = reading.audioOnly {
            let reason = audioOnlyNote(audioOnly, at: .readingRequest)
            return Result(step: .readingRequest,
                          verdict: .skipped(reason: reason),
                          spokenStatus: "Reading something. Skipped. \(reason)",
                          nextInstruction: nil,
                          retryAvailable: false)
        }
        if let unavailable = reading.unavailable {
            let reason = ReadingCaptureOutcome.spokenUnavailable(unavailable)
            return Result(step: .readingRequest,
                          verdict: .failed(reason: reason),
                          spokenStatus: "Reading something. \(reason)",
                          nextInstruction: "Point the glasses at something with writing on it and try again.",
                          retryAvailable: true)
        }
        guard let quality = reading.quality else {
            return Result(step: .readingRequest,
                          verdict: .failed(reason: "No photo came back."),
                          spokenStatus: "Reading something. No photo came back.",
                          nextInstruction: "Try again.",
                          retryAvailable: true)
        }
        guard quality == .usable else {
            let reason = ReadingCaptureOutcome.spokenInstruction(for: quality,
                                                                 isReadingRequest: true)
            return Result(step: .readingRequest,
                          verdict: .failed(reason: "The photo isn't clear enough to read from."),
                          spokenStatus: "Reading something. The photo isn't clear enough to read from.",
                          nextInstruction: reason,
                          retryAvailable: true)
        }
        switch reading.source {
        case .camera:
            return Result(step: .readingRequest,
                          verdict: .passed(note: nil),
                          spokenStatus: "Reading something. The photo is sharp enough to read fine print.",
                          nextInstruction: nil,
                          retryAvailable: false)
        case .fixture:
            let note = "This device has no glasses camera, so a stored test photo was measured instead. "
                + "It shows the check itself works; it doesn't prove your camera does."
            return Result(step: .readingRequest,
                          verdict: .passed(note: note),
                          spokenStatus: "Reading something. Passed on a stored test photo. \(note)",
                          nextInstruction: "Run this check again on the glasses to test the real camera.",
                          retryAvailable: false)
        }
    }

    // MARK: - Failure copy
    //
    // Each of these says what happened in the wearer's terms. None of them names an internal
    // state, because the row is read aloud to someone deciding whether to go out with this.

    private static func pausedCopy(_ pause: ListenerPauseReason) -> String {
        switch pause {
        case .sharedEngine:
            return "Another feature is using the microphone right now."
        case .silence:
            return "Listening is paused after a long quiet spell."
        }
    }

    private static func brokenCopy(_ broken: ListenerBreakReason) -> String {
        switch broken {
        case .engineStopped, .noRecognitionTask, .staleRecognitionTask:
            return "The app thinks it's listening, but nothing is reaching the microphone."
        case .recognitionEnded:
            return "The microphone is open, but speech recognition has stopped."
        case .tapMissing:
            return "The microphone is open and nothing is picking the sound up."
        }
    }

    private static func refusalCopy(_ refusal: ListenerRefusal) -> String {
        switch refusal {
        case .silentMode:
            return "Silent Mode is on, so the assistant isn't listening on its own."
        case .noIntent:
            return "Listening is switched off."
        case .noPermission:
            return BlindAssistantLaunchPolicy.SkipReason.microphonePermissionOff.summary
        }
    }

    private static func interruptedCopy(_ by: SpeechDeliveryOutcome.Interruption) -> String {
        switch by {
        case .bargeIn:
            return "The test line was cut off because something was heard on the microphone."
        case .stop:
            return "The test line was stopped before it finished."
        case .newUtterance:
            return "Something else spoke over the test line."
        }
    }

    private static func suppressedCopy(_ why: SpeechDeliveryOutcome.SuppressionReason) -> String {
        switch why {
        case .muted:
            return "Spoken output is muted, so the test line wasn't played."
        case .noRoute:
            return "There's nowhere to play sound right now, so the test line wasn't played."
        case .silentMode:
            return "Silent Mode is on, so the test line wasn't played."
        case .backgrounded:
            return "The app wasn't in the foreground, so the test line wasn't played."
        }
    }

    private static func suppressedInstruction(_ why: SpeechDeliveryOutcome.SuppressionReason) -> String {
        switch why {
        case .muted: return "Turn spoken output back on, then try again."
        case .noRoute: return "Put the glasses on, or check the audio output, then try again."
        case .silentMode: return "Turn Silent Mode off, then try again."
        case .backgrounded: return "Keep OpenGlasses open while the check runs, then try again."
        }
    }

}
