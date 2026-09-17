import AVFoundation
import Foundation
import UIKit

/// Plan FF P1/PR8 — the production probe behind the readiness walk-through: the one part of the
/// check that touches real hardware.
///
/// Everything it reads belongs to somebody else. The launch inputs are `AppState`'s, the camera
/// answer is `CameraReadiness`'s, the listening answer is `ListenerHealthPolicy`'s, the spoken
/// answer is `SpeechDeliveryOutcome`'s and the reading answer is `CaptureQualityReport`'s. Nothing
/// here decides anything — `ReadinessWalkthrough` does that, headlessly, from what this observed.
///
/// # What it gives back
///
/// The camera step is the only one that acquires anything the wearer would notice, and it gives it
/// back through the existing claim (Plan EW): `releaseStream(for:)` stops the stream **only** if
/// this claim is what started it and nothing else still wants it, so running the check on top of a
/// live session leaves that session's camera exactly as it found it. The spoken step starts
/// nothing: it reads the listener's health and speaks one line, so a wearer who was not listening
/// before the check is not listening after it.
@MainActor
final class LiveReadinessProbe: ReadinessStepProbing {

    /// Who the walk-through is, to the claim ledger.
    static let cameraOwner = CameraStreamClaims.Owner.readinessCheck

    /// How long the camera step waits for a decoded picture before calling it a failure.
    ///
    /// A cold glasses stream takes seconds to come up (`CameraReadiness.Phase.connecting` lives
    /// there for up to about twenty), so this is deliberately generous — but bounded, because a
    /// check that waits forever is a check that never says anything, which for a wearer who cannot
    /// see the spinner is the same as a crash.
    static let cameraEvidenceTimeout: TimeInterval = 12
    private static let pollInterval: TimeInterval = 0.25

    /// The line spoken to prove output works. Short, and it says what it is: a wearer who hears a
    /// stray sentence from their glasses should never have to wonder what asked for it.
    static let spokenTestLine = "This is the sound check. If you can hear this, spoken output works."

    private let launchInputs: () async -> BlindAssistantLaunchPolicy.Inputs
    private weak var camera: CameraService?
    private weak var wakeWord: WakeWordService?
    private weak var speech: TextToSpeechService?
    /// Overridable so a device build and the simulator take the same path through the runner.
    private let sharpStill: () -> SharpStillCapture?

    /// Set when this run's camera step actually took a claim, so the release is exact: releasing a
    /// claim we never took would tell the ledger a stream was given back that was never held.
    private var holdsCameraClaim = false
    /// Cached for the steps after the first, so one run reads permissions and registration once.
    private var cachedLaunchInputs: BlindAssistantLaunchPolicy.Inputs?

    init(launchInputs: @escaping () async -> BlindAssistantLaunchPolicy.Inputs,
         camera: CameraService?,
         wakeWord: WakeWordService?,
         speech: TextToSpeechService?) {
        self.launchInputs = launchInputs
        self.camera = camera
        self.wakeWord = wakeWord
        self.speech = speech
        self.sharpStill = { [weak camera] in
            guard let camera else { return nil }
            return SharpStillCapture(provider: camera,
                                     cameraSession: { camera.readinessNow.session })
        }
    }

    // MARK: - ReadinessStepProbing

    func evidence(for step: ReadinessWalkthrough.Step) async -> ReadinessWalkthrough.Evidence {
        switch step {
        case .registration, .permissions:
            // Re-read at the top of every run so a permission granted in iOS Settings between two
            // runs is seen, and cached within a run so the two steps cannot disagree with each
            // other about the same moment.
            return .launch(await currentLaunchInputs())
        case .cameraEvidence:
            return .camera(await cameraEvidence())
        case .spokenExchange:
            return .spokenExchange(await spokenExchangeEvidence())
        case .readingRequest:
            return .reading(await readingEvidence())
        }
    }

    func release(after step: ReadinessWalkthrough.Step) async {
        switch step {
        case .registration:
            break
        case .permissions:
            // The launch inputs are re-read at the start of the next run, not kept between runs.
            break
        case .cameraEvidence, .readingRequest:
            guard holdsCameraClaim, let camera else { return }
            holdsCameraClaim = false
            await camera.releaseStream(for: Self.cameraOwner)
        case .spokenExchange:
            break
        }
        if step == ReadinessWalkthrough.Step.allCases.last { cachedLaunchInputs = nil }
    }

    // MARK: - Camera

    private func cameraEvidence() async -> ReadinessWalkthrough.CameraEvidence {
        let inputs = await currentLaunchInputs()
        if let audioOnly = audioOnlyReason(inputs) {
            return ReadinessWalkthrough.CameraEvidence(audioOnly: audioOnly, streamClaimed: false)
        }
        guard let camera else {
            return ReadinessWalkthrough.CameraEvidence(streamClaimed: false)
        }
        do {
            try await camera.claimStream(for: Self.cameraOwner)
            holdsCameraClaim = true
        } catch {
            return ReadinessWalkthrough.CameraEvidence(streamClaimed: false)
        }
        let readiness = await waitForFreshEvidence(camera)
        return ReadinessWalkthrough.CameraEvidence(streamClaimed: true, readiness: readiness)
    }

    /// Poll until a decoded picture is fresh, or the bound runs out. Polls rather than subscribes
    /// on purpose: a frame subscription would make this a camera-pixel consumer, and the only
    /// thing the step needs is the readiness snapshot — no pixels ever reach this file.
    private func waitForFreshEvidence(_ camera: CameraService) async -> CameraReadiness {
        let deadline = Date().addingTimeInterval(Self.cameraEvidenceTimeout)
        var readiness = camera.readinessNow
        while !readiness.hasFreshVisualEvidence, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            readiness = camera.readinessNow
        }
        return readiness
    }

    // MARK: - Microphone and voice

    private func spokenExchangeEvidence() async -> ReadinessWalkthrough.SpokenExchangeEvidence {
        let permission: ListenerHealthState.Permission = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        }()
        guard let wakeWord else {
            return ReadinessWalkthrough.SpokenExchangeEvidence(listener: .refuse(.noIntent))
        }
        // `.automatic`, because the check is not a request to start listening — it is a question
        // about whether listening is working. Asking explicitly would barge in on a consumer that
        // deliberately holds the shared engine, which is the one thing this must not do.
        let state = wakeWord.healthState(origin: .automatic, permission: permission)
        let decision = ListenerHealthPolicy.decide(state)
        switch decision {
        case .healthy, .startFresh:
            break
        case .pausedDeliberately, .rebuild, .refuse:
            return ReadinessWalkthrough.SpokenExchangeEvidence(listener: decision)
        }
        guard let speech else {
            return ReadinessWalkthrough.SpokenExchangeEvidence(listener: decision,
                                                              speech: .failed(reason: "no speech service"))
        }
        let outcome = await speech.speakReporting(Self.spokenTestLine, urgency: .high)
        return ReadinessWalkthrough.SpokenExchangeEvidence(listener: decision, speech: outcome)
    }

    // MARK: - Reading

    private func readingEvidence() async -> ReadinessWalkthrough.ReadingEvidence {
        #if targetEnvironment(simulator)
        // A simulator has no glasses camera, so there is no still to measure and never will be.
        // Measuring the rendered fixture instead exercises the whole measurement chain the real
        // capture uses, and the walk-through reports it as a pass *with the note that says it was
        // a fixture* — see `ReadinessReadingFixture`.
        return ReadinessWalkthrough.ReadingEvidence(source: .fixture,
                                                    quality: ReadinessReadingFixture.measuredQuality())
        #else
        let inputs = await currentLaunchInputs()
        if let audioOnly = audioOnlyReason(inputs) {
            return ReadinessWalkthrough.ReadingEvidence(audioOnly: audioOnly)
        }
        guard let camera, let capture = sharpStill() else {
            return ReadinessWalkthrough.ReadingEvidence(unavailable: .noStill)
        }
        do {
            try await camera.claimStream(for: Self.cameraOwner)
            holdsCameraClaim = true
        } catch {
            return ReadinessWalkthrough.ReadingEvidence(unavailable: .noStill)
        }
        // Identity 0: this capture is never injected anywhere, so it belongs to no live session.
        // The admission check that identity feeds exists to stop a still reaching a *replaced*
        // session's model; nothing here reaches a model at all.
        switch await capture.capture(liveSessionIdentity: 0) {
        case .captured(_, let report):
            return ReadinessWalkthrough.ReadingEvidence(source: .camera, quality: report.quality)
        case .unavailable(let reason):
            return ReadinessWalkthrough.ReadingEvidence(unavailable: reason)
        }
        #endif
    }

    /// Read once per run: cached so the registration and permissions steps cannot disagree with
    /// each other about the same moment, and cleared after the last step so the next run sees a
    /// permission granted in iOS Settings in between.
    private func currentLaunchInputs() async -> BlindAssistantLaunchPolicy.Inputs {
        if let cachedLaunchInputs { return cachedLaunchInputs }
        let inputs = await launchInputs()
        cachedLaunchInputs = inputs
        return inputs
    }

    private func audioOnlyReason(_ inputs: BlindAssistantLaunchPolicy.Inputs)
        -> BlindAssistantLaunchPolicy.AudioOnlyReason? {
        if !inputs.cameraGranted { return .cameraPermissionOff }
        if !inputs.glassesReady { return .noGlasses }
        return nil
    }
}

/// The reading step's stand-in for a camera this build does not have.
///
/// On a simulator there are no glasses and therefore no still to measure, and a reading step that
/// simply failed there would tell a developer nothing and a wearer nothing at all. So the check
/// measures a **rendered fixture** through exactly the same `CaptureQualityReport.measure` the real
/// capture uses, and the walk-through reports it as a pass *with a note saying it was a fixture* —
/// never as a camera pass. A fixture proves the measurement works. It proves nothing about a
/// wearer's camera, and the copy says so out loud.
enum ReadinessReadingFixture {

    /// The rendered page. High-contrast text at a size a reading capture would resolve, because a
    /// flat fill has zero sharpness and would measure as blurry for the wrong reason.
    static func image(size: CGSize = CGSize(width: 960, height: 600)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            ("Readiness test page" as NSString).draw(at: CGPoint(x: 32, y: 120),
                                                     withAttributes: attributes)
            ("Take one daily with food" as NSString).draw(at: CGPoint(x: 32, y: 260),
                                                          withAttributes: attributes)
            ("Use by 03 / 2027" as NSString).draw(at: CGPoint(x: 32, y: 400),
                                                  withAttributes: attributes)
        }
    }

    /// Measure the fixture the way a real capture is measured.
    static func measuredQuality(now: Date = Date()) -> CaptureQualityReport.Quality? {
        let rendered = image()
        guard let jpeg = rendered.jpegData(compressionQuality: SharpStillCapture.jpegQuality) else {
            return nil
        }
        return CaptureQualityReport.measure(jpeg: jpeg,
                                            sourcePixelSize: rendered.pixelSize,
                                            deliveredPixelSize: rendered.pixelSize,
                                            scope: SharpStillCapture.scope,
                                            cameraSession: 0,
                                            liveSessionIdentity: 0,
                                            capturedAt: now).quality
    }
}
