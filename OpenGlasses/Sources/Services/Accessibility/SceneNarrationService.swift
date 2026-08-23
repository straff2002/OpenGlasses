import Combine
import Foundation
import UIKit

/// Continuous scene narration (Plan CV P2): the loop that watches through the glasses camera and,
/// when the wearer asks for it, describes the space as it changes.
///
/// The loop is the only new thing here — every decision it makes belongs to a core that shipped in
/// P1 and is tested on its own:
///
/// | Question | Answered by |
/// |---|---|
/// | Is this a new scene? | `FrameGate` + `PerceptualHash` (Plan AT) |
/// | Should we spend an inference? | `NarrationGate.evaluateGeneration` |
/// | Is this description worth saying? | `NarrationGate.evaluateSpeech` |
/// | May we put it on the floor now? | `AmbientSpeechArbiter(rules: .narration)` |
/// | Should any of this be running? | `NarrationSessionPolicy` |
/// | What have we seen lately? | `NarrationContext` |
///
/// **Silent by default.** `.start` lands in `.watching`: the loop describes and accumulates
/// grounding without speaking, so a later *"what's that?"* is answered against a scene the model
/// has already looked at. Speech is a separate, explicit mode.
///
/// **Local inference only.** Plan CV makes cloud narration a v1 non-goal — a continuously-running
/// loop becomes a continuous egress *and* a continuous bill, and both deserve their own decision
/// rather than riding in on an accessibility feature. The describe seam is wired to the on-device
/// VLM; there is no cloud fallback here on purpose.
///
/// Everything the loop touches is injected as a closure seam, so the whole thing is drivable
/// headlessly with `tickOnce(at:)` and a fake clock — no camera, no model, no `Wearables`.
@MainActor
final class SceneNarrationService: ObservableObject {
    static let shared = SceneNarrationService()

    // MARK: - Published state

    /// What the wearer asked for, with interruptions applied.
    @Published private(set) var mode: NarrationMode = .off
    @Published private(set) var isPerceiving = false
    @Published private(set) var isSpeakingMode = false

    /// Non-nil when perception stopped for a reason the wearer did not choose.
    ///
    /// P2 publishes it; **Plan CV P3 renders it** — for a wearer relying on narration, silence that
    /// isn't explained is indistinguishable from silence because nothing changed, which is the
    /// worst failure this feature has available. The policy decides the debt is owed, this surfaces
    /// it, and P3 owes the copy and the announcement.
    @Published private(set) var haltReason: NarrationSessionPolicy.Interruption?

    /// Non-nil when the loop is still watching but a standing condition has taken the ear —
    /// today, live ambient captions.
    ///
    /// Captions and narration are not two streams fighting for one ear (`AmbientCaptionService`
    /// never speaks — it writes the phone overlay and the lens). Narration yields anyway: it
    /// speaks over the same shared audio engine the caption recognizer listens on, with no voice
    /// processing on that path, so its own voice lands in the wearer's transcript as if a person
    /// had said it; and two simultaneous language streams are not something one person parses.
    /// Captions win because a caption is another person talking — unrepeatable — while the room
    /// will still be there in four seconds, and `FrameGate` will notice if it isn't.
    @Published private(set) var silenceReason: NarrationSessionPolicy.Interruption?

    /// Non-nil when narration cannot run on the connected glasses at all (Plan CV P3). Distinct
    /// from `haltReason`, which is a running session interrupted; this is a start that never
    /// happened, and the wearer must hear why rather than watch a switch flip back.
    @Published private(set) var unavailableReason: String?

    /// True from the instant narration asks for the camera until the stream is live or the ask has
    /// failed (Plan CV, camera ownership).
    ///
    /// Published because `AppState` folds it into the `.cameraUnavailable` edge. Without it the
    /// wearer is told "there's no live camera feed" a fraction of a second before narration starts
    /// the very feed they were told they didn't have — a halt announced against a condition that is
    /// already being fixed, which is worse than the silence P3 replaced. It is set **synchronously**
    /// on the request for exactly that reason: the claim is async, and the honest window has to
    /// open before the async work begins, not when it lands.
    @Published private(set) var isStartingCamera = false

    /// The most recent spoken notice, for the Settings surface.
    @Published private(set) var latestNotice: String?

    /// Every notice the loop has decided the wearer is owed, in order.
    ///
    /// The speech itself is fired as an unstructured task — TTS is async and a mode transition
    /// must not block a Settings toggle on it — so this is the deterministic record of the
    /// *decision*, and what tests assert against.
    private(set) var noticeLog: [String] = []

    @Published private(set) var latestDescription: String?
    @Published private(set) var describedCount = 0
    @Published private(set) var spokenCount = 0

    // MARK: - Tunables

    var gateRules = NarrationGateRules() {
        didSet { gate.rules = gateRules }
    }

    /// How often the loop looks. Not the description cadence — `NarrationGate`'s duty-cycle floor
    /// and dwell decide that. This is only how finely the loop can notice the moment they allow.
    var tickInterval: TimeInterval = 1.0

    /// Frames whose perceptual hash differs by less than this are the same scene.
    var frameHammingThreshold: Int = 4

    /// How long `FrameGate` waits before forcing a re-send of an unchanged scene. The loop ignores
    /// those re-sends (see `tickOnce`), so this only bounds how stale the gate's own baseline gets.
    var frameHeartbeat: TimeInterval = 30

    // MARK: - Seams

    /// The current camera frame, or nil if none is available.
    var currentFrame: (() -> UIImage?)?

    /// Describe a frame. Wired to the on-device VLM; nil result means the inference didn't produce
    /// anything usable, which the loop treats as "nothing to say", not as an error worth speaking.
    var describeFrame: ((Data) async -> String?)?

    /// Put an utterance on the floor.
    var speakUtterance: ((String) async -> Void)?

    /// Whether TTS currently owns the floor.
    var isTTSBusy: () -> Bool = { false }

    /// Speak a system notice — a halt explanation or a refusal (Plan CV P3).
    ///
    /// Deliberately **not** routed through `AmbientSpeechArbiter`: the arbiter exists to keep
    /// ambient descriptions from crowding the ear, and it flushes its queue on exactly the
    /// transitions these notices explain. A notice queued there would be dropped by the very halt
    /// it was announcing.
    var speakNotice: ((String) async -> Void)?

    /// Whether the connected glasses can support narration, and if not, what to tell the wearer.
    /// Defaults to available so headless tests and unwired callers behave as before.
    var cameraAvailability: () -> CameraFeatureAvailability = { .available }

    /// Take a claim on the glasses video stream, starting it if nothing else has. Returns nil on
    /// success, or the reason it failed — narration owns telling the wearer, not the camera layer.
    ///
    /// Unwired (nil) means "somebody else is responsible for the camera", which is what keeps every
    /// existing headless test behaving exactly as it did before narration learned to do this.
    var claimCamera: (() async -> String?)?

    /// Give the claim back. Stops the stream only if narration's claim started it and nothing else
    /// still wants it — see `CameraStreamClaims`.
    var releaseCamera: (() async -> Void)?

    /// Whether frames are already flowing. Read at claim time, and only to decide what the wearer
    /// is told: a camera that is already on has no cold start to announce and no power cost to
    /// refuse.
    var isCameraStreaming: () -> Bool = { false }

    /// The current power posture (Plan BV). Narration is the app's most expensive continuous
    /// feature and the camera is its most expensive part, so `reserve` refuses the start.
    var powerPosture: () -> PowerPosture = { .normal }

    /// Injected clock, seconds. No `Date()` inside the loop, so tests drive time directly.
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    /// Perceptual hash of a frame. Injected so tests can drive scene changes without images.
    var hashFrame: (UIImage) -> UInt64? = { PerceptualHash.dhash($0) }

    /// JPEG compression for the frame handed to the model. 0.6 rather than the on-demand path's
    /// 0.7: this runs continuously, and the description is a sentence about a room, not a reading
    /// of small print.
    var frameCompressionQuality: CGFloat = 0.6

    // MARK: - Cores

    private var policy = NarrationSessionPolicy()
    private var gate = NarrationGate()
    private var frameGate: FrameGate
    private var arbiter = AmbientSpeechArbiter<String>(rules: .narration)
    private var notices = NarrationVoiceNotices()
    private(set) var context = NarrationContext()

    // MARK: - Loop state

    private var timer: Timer?
    /// An inference is in flight. The on-device model allows one generation at a time, and a
    /// second entrant would be refused by `LocalLLMService` anyway — better not to ask.
    private var describing = false
    /// An utterance is being handed to TTS. Distinct from `isTTSBusy`, which reports the engine.
    private var emitting = false

    /// Whether narration currently holds a camera claim. Tracked here as well as in
    /// `CameraStreamClaims` so the decision to claim or release can be made synchronously, before
    /// any `await`, which is what keeps the interruption edges from crossing.
    private var holdsCameraClaim = false

    /// Re-entrancy guard for `prepareCamera(for:)`. Claiming the camera publishes
    /// `isStartingCamera`, which drives an interruption edge straight back into `apply` — and that
    /// nested call must apply its interruption (it is a real fact) without re-deciding the camera,
    /// or a claim in progress would immediately be released by the notification that it started.
    private var reconcilingCamera = false

    /// The warm-up notice, held from the moment the claim begins until the transition it
    /// accompanies has been resolved. See `apply` for why it can't simply be spoken on the spot.
    private var pendingCameraWarmup: String?

    private init() {
        frameGate = FrameGate(hammingThreshold: 4, heartbeat: 30)
    }

    /// Test seam: a fresh instance, never the shared one. Exercising `.shared` pulls in the real
    /// camera and `Wearables`, which fatals headlessly.
    static func makeForTesting() -> SceneNarrationService {
        SceneNarrationService()
    }

    // MARK: - Commands

    /// Apply a parsed voice command (`AssistiveRouter.narrationCommand(in:)`).
    ///
    /// Routed through the same entry points as the Settings switches rather than straight into the
    /// policy: the gates those entry points apply — device tier, power posture, and taking the
    /// camera — are properties of *starting narration*, not of starting it from one particular
    /// surface. Spoken commands previously bypassed all of them, which is exactly the audience
    /// least able to fall back to the switch.
    func handle(_ command: AssistiveRouter.NarrationCommand) {
        switch command {
        case .start: start()
        case .startNarrating: startNarrating()
        case .stopNarrating: stopNarrating()
        case .stop: stop()
        }
    }

    /// Start watching — silently. Entering the mode never starts speaking on its own.
    ///
    /// Refuses out loud on glasses that can't provide live frames (Plan CV P3): a switch that flips
    /// itself back with no explanation is the same unexplained-silence failure in a different
    /// costume, and the wearer most likely to hit it is the one least able to see the switch.
    func start() {
        guard passesCameraGate(), passesPowerGate() else { return }
        apply(.start)
    }

    func startNarrating() {
        guard passesCameraGate(), passesPowerGate() else { return }
        apply(.startNarrating)
    }

    /// True when narration can run at all. On `.unavailable` this records and speaks the reason.
    ///
    /// `.degraded` is allowed through: it means the camera works differently, not that it can't
    /// feed this loop, and the gate's own copy already carries the caveat.
    private func passesCameraGate() -> Bool {
        if case let .unavailable(reason) = cameraAvailability() {
            unavailableReason = reason
            NSLog("[SceneNarration] Refused — %@", reason)
            announce(NarrationVoiceNotices.refusalCopy(reason))
            return false
        }
        unavailableReason = nil
        return true
    }

    /// Whether the glasses have the power to run narration's camera, and if not, says so.
    ///
    /// **Only a refusal when narration would actually have to start the camera.** If frames are
    /// already flowing for something else, narration adds a VLM but no camera, and refusing it
    /// would be economising on a cost we are not about to pay. `NarrationVoiceNotices.powerRefusal`
    /// owns which postures refuse and why `conserve` is not one of them.
    private func passesPowerGate() -> Bool {
        guard !isCameraStreaming(),
              let refusal = NarrationVoiceNotices.powerRefusal(posture: powerPosture()) else {
            return true
        }
        unavailableReason = refusal
        NSLog("[SceneNarration] Refused on power posture %@", powerPosture().label)
        announce(refusal)
        return false
    }

    /// Stop speaking, keep watching. Grounding is the cheap half and there is no reason to lose it.
    func stopNarrating() { apply(.stopNarrating) }

    /// Leave the mode entirely.
    func stop() { apply(.stop) }

    /// Report something that overrides what the wearer asked for. Speech-only interruptions
    /// (`.userTurn`, `.realtimeSession`) keep the loop watching; the rest halt it.
    func noteInterruption(_ interruption: NarrationSessionPolicy.Interruption, active: Bool) {
        apply(.interruption(interruption, active: active))
    }

    private func apply(_ event: NarrationSessionPolicy.Event) {
        // The camera decision is made against the state this event is *about* to produce, and acted
        // on first. Order is the whole trick: claiming publishes `isStartingCamera`, which clears
        // the `.cameraUnavailable` edge, so by the time the event lands the wearer is not told
        // about an absent camera that is already on its way up.
        prepareCamera(for: event)

        let transition = policy.apply(event)
        publish(transition.to)

        if transition.flushSpeechQueue {
            arbiter.reset()
        }
        if transition.to.mode == .off {
            teardown()
        } else if transition.to.isPerceiving {
            ensureTimer()
        } else {
            // Halted, not ended: the wearer's requested mode survives, so keep the cores' state
            // and only stop looking.
            invalidateTimer()
        }

        if let began = transition.haltBegan {
            NSLog("[SceneNarration] Halted — %@", began.rawValue)
        }
        if let ended = transition.haltEnded {
            NSLog("[SceneNarration] Resumed after %@", ended.rawValue)
        }
        if let began = transition.silenceBegan {
            NSLog("[SceneNarration] Quiet (still watching) — %@", began.rawValue)
        }
        if let ended = transition.silenceEnded {
            NSLog("[SceneNarration] Speaking again after %@", ended.rawValue)
        }

        // Plan CV P3: say why, to the wearer who was being spoken to. `NarrationVoiceNotices`
        // owns the restraint — who hears it, and how often. Called unconditionally, before the
        // warm-up is considered, because its bookkeeping (which halt has been announced) has to
        // advance whether or not the copy is the one that gets spoken.
        let transitionCopy = notices.notice(for: transition, requestedMode: policy.requestedMode)

        // The warm-up goes first when both are owed: it is the reply to what the wearer just did.
        //
        // `!reconcilingCamera` is load-bearing rather than defensive. Taking the camera publishes
        // `isStartingCamera`, whose edge re-enters `apply` *before* the event that queued the
        // warm-up has been applied — so without this guard the warm-up is spoken by that nested
        // call, and the real transition, arriving a moment later with the warm-up already consumed,
        // announces the resumption the warm-up exists to displace.
        if !reconcilingCamera, let warmup = pendingCameraWarmup {
            pendingCameraWarmup = nil
            announce(warmup)
            // A *resumption* displaced by a warm-up is dropped rather than queued behind it.
            // "Scene narration is back on" is not true while the camera is still coming up, and
            // following it with "starting the camera, this takes a few seconds" tells the wearer
            // two contradictory things about one moment; the warm-up is the honest version of the
            // same news. A fresh halt or silence is never dropped this way — that is different
            // news, not the same news early.
            if let transitionCopy, !isResumption(transition) { announce(transitionCopy) }
        } else if let transitionCopy {
            announce(transitionCopy)
        }
    }

    /// Whether the copy `NarrationVoiceNotices` produced for this transition is a resumption
    /// ("back on" / "speaking again") rather than a fresh halt or silence. Mirrors that type's own
    /// precedence, so the two cannot drift into disagreeing about what a transition means.
    private func isResumption(_ transition: NarrationSessionPolicy.Transition) -> Bool {
        transition.haltBegan == nil && transition.haltBlockedRequest == nil
            && transition.silenceBegan == nil
            && (transition.haltEnded != nil || transition.silenceEnded != nil)
    }

    // MARK: - Camera ownership (Plan CV)

    /// Take or give back the camera claim for the state `event` is about to produce.
    ///
    /// A value-type policy makes this straightforward: apply the event to a copy and ask the copy
    /// what it wants, without committing anything.
    private func prepareCamera(for event: NarrationSessionPolicy.Event) {
        guard claimCamera != nil, !reconcilingCamera else { return }
        var next = policy
        next.apply(event)
        guard next.wantsCamera != holdsCameraClaim else { return }

        reconcilingCamera = true
        defer { reconcilingCamera = false }
        if next.wantsCamera {
            beginCameraClaim()
        } else {
            endCameraClaim()
        }
    }

    private func beginCameraClaim() {
        guard let claimCamera else { return }
        // Set before anything can `await`, and before `isStartingCamera`: the edge that publishing
        // it triggers comes straight back through `apply`, and a wanted-but-unheld camera seen
        // there would be claimed a second time.
        holdsCameraClaim = true
        // A claim already in flight will land for us — including one the wearer cancelled and
        // restarted inside the cold start.
        guard !isStartingCamera else { return }

        if !isCameraStreaming() {
            pendingCameraWarmup = NarrationVoiceNotices.warmingCopy(posture: powerPosture())
        }
        isStartingCamera = true

        Task { [weak self] in
            let failure = await claimCamera()
            guard let self else { return }
            guard let failure else {
                self.isStartingCamera = false
                // The wearer may well have turned narration off during the twenty seconds we spent
                // starting a camera for them. The release was deferred to here precisely because
                // handing back a stream that had not started yet would have left it running for a
                // loop that has stopped.
                if !self.holdsCameraClaim { self.performCameraRelease() }
                return
            }
            // Order matters as much here as on the way in. `.stop` lands first so the requested
            // mode is `.off` before `isStartingCamera` falls — otherwise the `.cameraUnavailable`
            // edge fires into a live session and the wearer hears the generic halt copy on top of
            // the specific reason below.
            self.pendingCameraWarmup = nil
            self.apply(.stop)
            self.isStartingCamera = false
            self.unavailableReason = failure
            NSLog("[SceneNarration] Camera claim failed — %@", failure)
            self.announce(NarrationVoiceNotices.refusalCopy(failure))
        }
    }

    private func endCameraClaim() {
        guard holdsCameraClaim else { return }
        holdsCameraClaim = false
        pendingCameraWarmup = nil
        // Mid-claim, the release waits for the claim to land. Releasing a stream that has not
        // started yet gives back nothing, and the start then completes into nobody's hands — the
        // glasses streaming indefinitely for a loop that is no longer running.
        guard !isStartingCamera else { return }
        performCameraRelease()
    }

    private func performCameraRelease() {
        guard let releaseCamera else { return }
        Task { await releaseCamera() }
    }

    /// Record and speak a notice.
    private func announce(_ copy: String) {
        noticeLog.append(copy)
        latestNotice = copy
        if let speakNotice {
            Task { await speakNotice(copy) }
        }
    }

    private func publish(_ state: NarrationSessionPolicy.State) {
        mode = state.mode
        isPerceiving = state.isPerceiving
        isSpeakingMode = state.isSpeaking
        haltReason = state.haltReason
        silenceReason = state.silenceReason
    }

    private func teardown() {
        invalidateTimer()
        gate.reset()
        frameGate.reset()
        arbiter.reset()
        context.reset()
        notices.reset()
        noticeLog.removeAll()
        latestNotice = nil
        latestDescription = nil
        describedCount = 0
        spokenCount = 0
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        // A fresh frame gate on every resume, so the first frame back counts as `.firstFrame` and
        // gets described. That is what someone returning from a halt needs: after the app comes
        // back from the background the wearer may be somewhere else entirely, and a gate still
        // holding the old baseline would call the new room "unchanged".
        frameGate = FrameGate(hammingThreshold: frameHammingThreshold, heartbeat: frameHeartbeat)
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickOnce(at: self?.clock() ?? 0) }
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Grounding

    /// The rolling grounding context as a prompt fragment, for a question answered while the loop
    /// is running. Nil when there is nothing worth grounding against.
    ///
    /// This is what the silent half is *for*: the wearer's *"what's that?"* is answered against a
    /// scene the model already looked at rather than a fresh capture-and-describe round trip.
    func groundingFragment() -> String? {
        context.promptFragment(at: clock())
    }

    // MARK: - The loop

    /// One pass. Public so tests drive it directly with an injected clock instead of a timer.
    ///
    /// The frame is taken **once** and used for both halves. Sampling it twice would let it change
    /// (or vanish) between noticing the scene change and describing it, which is how you get a
    /// description of one room attributed to the moment the wearer entered another.
    func tickOnce(at now: TimeInterval) async {
        guard policy.state.isPerceiving else { return }

        let frame = currentFrame?()
        if let frame { noteSceneChangeIfDistinct(frame, at: now) }
        await generateIfDue(frame, at: now)
        await pumpSpeech(at: now)
    }

    /// Feed the frame gate, and tell `NarrationGate` about **genuine** scene changes only.
    ///
    /// `.heartbeat` is deliberately dropped: `FrameGate` forces a periodic re-send of an unchanged
    /// scene so a consumer's context can't go stale, and a forced re-send of a scene that did not
    /// change is exactly what must not produce a fresh announcement. `.firstFrame` **is** taken —
    /// it is the wearer's first look at wherever they are, and a loop that stayed silent until
    /// something moved would say nothing at all to someone who turned it on standing still.
    private func noteSceneChangeIfDistinct(_ frame: UIImage, at now: TimeInterval) {
        guard let hash = hashFrame(frame) else { return }
        guard frameGate.evaluate(hash: hash, now: now) == .send else { return }
        switch frameGate.lastSendReason {
        case .distinct, .firstFrame:
            gate.noteSceneChange(at: now)
        case .heartbeat, .none:
            break
        }
    }

    /// Everything that could stop us is checked **before** `evaluateGeneration`, deliberately: that
    /// call consumes the pending scene change and restarts the duty-cycle clock, so asking it and
    /// then bailing would swallow a genuine scene change the wearer never heard about.
    private func generateIfDue(_ frame: UIImage?, at now: TimeInterval) async {
        guard !describing,
              let describeFrame,
              let frame,
              let data = frame.jpegData(compressionQuality: frameCompressionQuality) else { return }
        guard gate.evaluateGeneration(at: now).isGenerate else { return }

        describing = true
        defer { describing = false }

        guard let raw = await describeFrame(data) else { return }
        let description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        // The session may have ended during the await.
        guard policy.state.isPerceiving else { return }

        let speaking = policy.state.isSpeaking
        // The speech gate runs only when we may actually speak. Scoring in watching mode would
        // move the spoken baseline against something nobody heard, and the first description after
        // "start narrating" would then be suppressed as a rephrase of a silence.
        var willSpeak = false
        if speaking, case .speak = gate.evaluateSpeech(description) {
            willSpeak = true
        }

        context.record(description, at: now, spoken: willSpeak)
        latestDescription = description
        describedCount += 1

        if willSpeak {
            arbiter.enqueue(description, dedupKey: description, at: now)
        }
    }

    /// Hand the arbiter's next allowed utterance to TTS, if the moment allows one.
    private func pumpSpeech(at now: TimeInterval) async {
        guard !emitting, let speakUtterance else { return }
        let suppressed = !policy.state.isSpeaking
        guard let pending = arbiter.next(at: now, ttsBusy: isTTSBusy(), suppressed: suppressed) else {
            return
        }

        emitting = true
        defer { emitting = false }
        spokenCount += 1
        await speakUtterance(pending.payload)
    }

    // MARK: - Diagnostics

    /// Counters the cores keep, surfaced for Settings and for P4's device measurement.
    var diagnostics: (described: Int, spoken: Int, suppressedRephrases: Int, framesDeduped: Double) {
        (describedCount, spokenCount, gate.suppressedRephraseCount, frameGate.dedupRatio)
    }
}
