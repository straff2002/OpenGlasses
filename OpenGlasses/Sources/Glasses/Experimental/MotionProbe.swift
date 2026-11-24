#if DAT_EXPERIMENTAL
import Foundation

// Plan NB §5. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// The Motion probe (Plan NB §5): a one-minute run from the Developer panel that adds the band's
/// motion (`WristMotionSource`) and its inputs with the drag stream (the Inputs probe's
/// configuration) on the shared session, and walks the wearer through four prompts on the phone:
/// pinch and hold; pinch, hold and turn clockwise; the same anticlockwise; pinch, hold and move
/// the arm left. Everything goes to `MotionProbeLedger` as aggregates per prompt, so the device
/// pass can say whether the band's samples reach a native app, what a held pinch sends, which way
/// clockwise turns the twist, and whether Meta takes the twist for the volume. It maps nothing.
///
/// - **One probe at a time.** The session has one Inputs capability, so Start is refused while the
///   Inputs probe runs, and the page view's band and wrist channels hand theirs back first
///   (`DATExperimentalFeatures.startMotionProbe`).
/// - **It stops itself** when the prompts are done, when the link drops, when the session stops
///   underneath it, when Motion reports an error, or at the wearer's Stop.
/// - **Inputs failing is no stop**: the motion half is still worth having, and the error is kept.
@MainActor
final class MotionProbe: ObservableObject {
    enum Phase: Equatable { case idle, starting, running }

    @Published private(set) var phase: Phase = .idle
    /// The prompt whose window is open, while running.
    @Published private(set) var prompt: MotionProbePrompt?

    private let motionSource: WristMotionSource
    private let inputsSource: InputsSource
    private let ledger: MotionProbeLedger
    private let promptWindow: Duration
    private let verdict: () -> DATExperimentalPolicy.Verdict
    private let otherProbeRunning: () -> Bool
    /// The phone's output volume (0–1), for "did Meta take the twist".
    private let outputVolume: () -> Float?

    private var connected: [String] = []
    private var deviceId: String?
    private var motion: MotionChannel?
    private var inputs: InputsChannel?
    private var prompts: Task<Void, Never>?
    /// Bumped at every start and every stop, so a late callback from an old run is ignored.
    private var run = 0
    private var begun = ContinuousClock.now

    init(motionSource: WristMotionSource,
         inputsSource: InputsSource,
         ledger: MotionProbeLedger,
         promptWindow: Duration = MotionProbePolicy.promptWindow,
         verdict: @escaping () -> DATExperimentalPolicy.Verdict,
         otherProbeRunning: @escaping () -> Bool,
         outputVolume: @escaping () -> Float?) {
        self.motionSource = motionSource
        self.inputsSource = inputsSource
        self.ledger = ledger
        self.promptWindow = promptWindow
        self.verdict = verdict
        self.otherProbeRunning = otherProbeRunning
        self.outputVolume = outputVolume
    }

    var isRunning: Bool { phase != .idle }

    func update(connectedDeviceIds ids: [String]) {
        connected = ids
        if let deviceId, !ids.contains(deviceId) { stop(.linkDown) }
    }

    /// Begins a run, or says why not. Returns once Motion and Inputs are added (or have failed);
    /// the prompts then run on their own.
    @discardableResult
    func start() async -> MotionProbeRefusal? {
        if let refusal = MotionProbePolicy.refusal(verdict: verdict(), connected: !connected.isEmpty,
                                                   running: isRunning, otherProbeRunning: otherProbeRunning()) {
            ledger.refused(refusal)
            PrivacyLog.device(.glasses, .motionProbeRefused, reason: PrivacyToken(refusal.rawValue))
            return refusal
        }
        let id = connected[0]
        run += 1
        let thisRun = run
        deviceId = id
        phase = .starting
        begun = .now
        ledger.begin()
        PrivacyLog.device(.glasses, .motionProbeStarted)
        do {
            let opened = try await motionSource.open(deviceId: id, handlers: motionHandlers(for: thisRun))
            guard run == thisRun else { opened.stop(); return nil }
            motion = opened
        } catch {
            guard run == thisRun else { return nil }
            let failure = (error as? MotionChannelFailure) ?? .unknown
            ledger.recordError(failure.rawValue)
            PrivacyLog.device(.glasses, .motionProbeError, reason: PrivacyToken(failure.rawValue))
            stop(.failed)
            return nil
        }
        do {
            let opened = try await inputsSource.open(deviceId: id, handlers: inputsHandlers(for: thisRun))
            guard run == thisRun else { opened.stop(); return nil }
            inputs = opened
        } catch {
            guard run == thisRun else { return nil }
            let failure = (error as? InputsProbeFailure) ?? .unknown
            ledger.recordError("inputs-" + failure.rawValue)
            PrivacyLog.device(.glasses, .motionProbeError, reason: PrivacyToken("inputs-" + failure.rawValue))
        }
        phase = .running
        let window = promptWindow
        prompts = Task { @MainActor [weak self] in
            for prompt in MotionProbePrompt.allCases {
                guard let self, self.run == thisRun else { return }
                self.prompt = prompt
                self.ledger.beginPrompt(prompt, volume: self.outputVolume())
                PrivacyLog.device(.glasses, .motionProbePrompt, state: PrivacyToken(prompt.rawValue))
                guard (try? await Task.sleep(for: window)) != nil else { return }
                guard self.run == thisRun else { return }
                self.closePrompt()
            }
            guard let self, self.run == thisRun else { return }
            self.stop(.finished)
        }
        return nil
    }

    /// Ends the run, if one is going.
    func stop(_ reason: MotionProbeStopReason = .wearerStopped) {
        guard isRunning else { return }
        run += 1
        prompts?.cancel()
        prompts = nil
        motion?.stop()
        motion = nil
        inputs?.stop()
        inputs = nil
        deviceId = nil
        prompt = nil
        phase = .idle
        ledger.end(reason, volume: outputVolume())
        PrivacyLog.device(.glasses, .motionProbeStopped, reason: PrivacyToken(reason.rawValue),
                          count: Int((ContinuousClock.now - begun).components.seconds))
    }

    private func closePrompt() {
        let volume = outputVolume()
        ledger.endPrompt(volume: volume)
        guard let record = ledger.current?.prompts.last else { return }
        PrivacyLog.device(.glasses, .motionProbePrompt, state: PrivacyToken(record.prompt.rawValue),
                          count: record.bandSamples, success: record.volumeChanged)
    }

    private func motionHandlers(for thisRun: Int) -> MotionChannelHandlers {
        MotionChannelHandlers(
            onSample: { [weak self] sample in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordBandSample(sample)
            },
            onOtherSample: { [weak self] origin in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordOtherSample(origin)
            },
            onState: { [weak self] state in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordState(state)
            },
            onFailure: { [weak self] failure in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordError(failure.rawValue)
                PrivacyLog.device(.glasses, .motionProbeError, reason: PrivacyToken(failure.rawValue))
                self.stop(.capabilityFailed)
            },
            onEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.stop(.sessionEnded)
            })
    }

    private func inputsHandlers(for thisRun: Int) -> InputsChannelHandlers {
        InputsChannelHandlers(
            onInput: { [weak self] input in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordInput(input)
            },
            onState: { _ in },
            onFailure: { [weak self] failure in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordError("inputs-" + failure.rawValue)
                // A failed capability stays attached until it is removed.
                self.inputs?.stop()
                self.inputs = nil
            },
            onEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.stop(.sessionEnded)
            },
            onInputsEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordError("inputs-ended")
                self.inputs?.stop()
                self.inputs = nil
            })
    }
}
#endif
