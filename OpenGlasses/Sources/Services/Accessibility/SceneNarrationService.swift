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
    func handle(_ command: AssistiveRouter.NarrationCommand) {
        switch command {
        case .start: apply(.start)
        case .startNarrating: apply(.startNarrating)
        case .stopNarrating: apply(.stopNarrating)
        case .stop: apply(.stop)
        }
    }

    /// Start watching — silently. Entering the mode never starts speaking on its own.
    ///
    /// Refuses out loud on glasses that can't provide live frames (Plan CV P3): a switch that flips
    /// itself back with no explanation is the same unexplained-silence failure in a different
    /// costume, and the wearer most likely to hit it is the one least able to see the switch.
    func start() {
        guard passesCameraGate() else { return }
        apply(.start)
    }

    func startNarrating() {
        guard passesCameraGate() else { return }
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
        // owns the restraint — who hears it, and how often.
        if let copy = notices.notice(for: transition, requestedMode: policy.requestedMode) {
            announce(copy)
        }
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
