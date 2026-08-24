import AVFoundation
import Foundation

/// The single mic source that streams and recordings talk to.
///
/// Capture consumers register here instead of on the always-on listener directly. The router owns
/// the registry, and underneath it swaps between the listener's shared tap and a standalone engine
/// (`AudioSourceArbiter`) as listening is toggled — a consumer registered here never notices the
/// handover, and never goes silent because the wearer turned the wake word off mid-stream.
///
/// It also applies `AssistantAudioGate`: while the assistant is speaking out of the phone speaker,
/// consumers receive zero-filled buffers of the same shape rather than the mic hearing the reply and
/// muxing it back into the capture. Buffers are silenced, never dropped, because the broadcast's
/// audio PTS runs off a sample-count clock and a gap would shift A/V sync permanently.
///
/// Wake-word recognition is not routed through here at all — the recognizer keeps reading the
/// listener's own tap directly, so none of this can affect wake-word detection.
@MainActor
final class CaptureAudioRouter: ObservableObject, BroadcastAudioProviding {
    /// The id this router registers under on whichever source is active.
    static let sourceConsumerId = "capture_audio_router"

    /// The source currently feeding consumers. Published for diagnostics; nothing gates on it.
    @Published private(set) var activeSource: CaptureAudioSource = .none

    private weak var wakeTap: (any BroadcastAudioProviding)?
    private let standalone: (any CaptureAudioEngineProviding)?
    private let isPhoneSpeakerOutput: @MainActor () -> Bool
    private let includeAssistantVoice: @MainActor () -> Bool

    private var consumers: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let fanout = CaptureAudioFanout()
    private var arbiter = AudioSourceArbiter()
    private var wakeListening = false
    private var assistantSpeaking = false
    /// Source changes are serialised through one chained task: starting the standalone engine is
    /// async, and a listening toggle that arrives mid-start must not interleave with it.
    private var sourceTask: Task<Void, Never>?

    init(
        wakeTap: (any BroadcastAudioProviding)?,
        standalone: (any CaptureAudioEngineProviding)?,
        isPhoneSpeakerOutput: @escaping @MainActor () -> Bool = { CaptureAudioRouter.outputIsPhoneSpeaker() },
        includeAssistantVoice: @escaping @MainActor () -> Bool = { Config.captureIncludesAssistantVoice }
    ) {
        self.wakeTap = wakeTap
        self.standalone = standalone
        self.isPhoneSpeakerOutput = isPhoneSpeakerOutput
        self.includeAssistantVoice = includeAssistantVoice
    }

    // MARK: - Inputs

    /// The always-on listener started or stopped. Drives the source handover.
    func setWakeListening(_ listening: Bool) {
        guard wakeListening != listening else { return }
        wakeListening = listening
        refreshSource()
    }

    /// The assistant started or stopped speaking. Drives the gate.
    func setAssistantSpeaking(_ speaking: Bool) {
        guard assistantSpeaking != speaking else { return }
        assistantSpeaking = speaking
        refreshGate()
    }

    /// Re-evaluate the gate without a speaking change. The setting is otherwise read when speech
    /// starts, so a flip made mid-reply takes effect from the next reply; this is the seam for
    /// making it immediate if that ever turns out to matter.
    func refreshAssistantGate() {
        refreshGate()
    }

    // MARK: - BroadcastAudioProviding

    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        consumers[id] = handler
        publishConsumers()
        refreshSource()
    }

    func removeAudioBufferConsumer(id: String) {
        guard consumers.removeValue(forKey: id) != nil else { return }
        publishConsumers()
        refreshSource()
    }

    /// Detach from whatever source is attached (app teardown).
    func shutdown() {
        consumers.removeAll()
        publishConsumers()
        run(arbiter.reset())
        activeSource = arbiter.source
    }

    /// Await any in-flight source change. Test seam — production never needs to wait.
    func settleForTesting() async {
        await sourceTask?.value
    }

    // MARK: - Source arbitration

    private func refreshSource() {
        let conditions = CaptureAudioConditions(
            wakeListening: wakeListening,
            captureActive: !consumers.isEmpty
        )
        let commands = arbiter.apply(conditions)
        guard !commands.isEmpty else { return }
        activeSource = arbiter.source
        NSLog("[CaptureAudio] Source → %@ (listening: %@, capturing: %@)",
              arbiter.source.rawValue, wakeListening ? "yes" : "no",
              conditions.captureActive ? "yes" : "no")
        run(commands)
    }

    private func run(_ commands: [CaptureAudioCommand]) {
        guard !commands.isEmpty else { return }
        let previous = sourceTask
        sourceTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            for command in commands { await self.execute(command) }
        }
    }

    private func execute(_ command: CaptureAudioCommand) async {
        let fanout = self.fanout
        switch command {
        case .attachToWakeTap:
            wakeTap?.addAudioBufferConsumer(id: Self.sourceConsumerId) { buffer in
                fanout.dispatch(buffer)
            }
        case .detachFromWakeTap:
            wakeTap?.removeAudioBufferConsumer(id: Self.sourceConsumerId)
        case .startStandalone:
            guard let standalone else {
                NSLog("[CaptureAudio] No standalone engine — capture stays video-only while listening is off")
                return
            }
            standalone.addAudioBufferConsumer(id: Self.sourceConsumerId) { buffer in
                fanout.dispatch(buffer)
            }
            do {
                try await standalone.start()
            } catch {
                standalone.removeAudioBufferConsumer(id: Self.sourceConsumerId)
                NSLog("[CaptureAudio] Standalone engine failed to start: %@", error.localizedDescription)
            }
        case .stopStandalone:
            standalone?.removeAudioBufferConsumer(id: Self.sourceConsumerId)
            standalone?.stop()
        }
    }

    // MARK: - Assistant gate

    private func refreshGate() {
        // Only ask for the route while speech is actually playing — the query hits the live session
        // and the answer is meaningless otherwise.
        let onSpeaker = assistantSpeaking ? isPhoneSpeakerOutput() : false
        let decision = AssistantAudioGate.decide(
            ttsSpeaking: assistantSpeaking,
            ttsOnPhoneSpeaker: onSpeaker,
            includeAssistantVoice: includeAssistantVoice()
        )
        fanout.setSilenced(decision == .silence)
    }

    private func publishConsumers() {
        fanout.setConsumers(Array(consumers.values))
    }

    /// Whether the shared session's current output route is the phone's own speaker (or receiver) —
    /// the routes where the mic can hear what the assistant is saying.
    static func outputIsPhoneSpeaker() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        return outputs.contains { $0 == .builtInSpeaker || $0 == .builtInReceiver }
    }
}
