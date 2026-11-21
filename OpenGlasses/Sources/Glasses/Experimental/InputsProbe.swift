#if DAT_EXPERIMENTAL
import Foundation

// Plan JV P2. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// The Inputs probe (Plan JV P2): a diagnostics run from the Developer panel that adds the glasses'
/// touch inputs on the shared session and records every one, so the device pass can say which
/// inputs the glasses send, whether Meta still acts on them, and what holding the session costs the
/// battery. It maps nothing.
///
/// - **One run at a time, and only with a link.** Start is refused without a connected pair or
///   while a run is going (`InputsProbePolicy.refusal`). The camera and the lens may be on: the
///   probe joins the session they share.
/// - **Running means `.active`.** Adding Inputs only begins activation, so the run stays `.starting`
///   until the capability reports `.active` (the SDK gives up after 10 s with `activationTimeout`).
/// - **It stops itself** after five minutes, when the device's link drops, when the session stops
///   underneath it, when the capability reports an error (a failed capability stays attached until
///   it is removed) or its event stream finishes, or at the wearer's Stop — whichever comes first.
/// - **Everything goes to `InputsProbeLedger`** for the support report and is logged as case names
///   and numbers. The device is never named.
@MainActor
final class InputsProbe: ObservableObject {
    enum Phase: Equatable { case idle, starting, running }

    @Published private(set) var phase: Phase = .idle

    private let source: InputsSource
    private let ledger: InputsProbeLedger
    private let timeLimit: Duration
    /// The experimental verdict, asked with the switch on: the press is the switch.
    private let verdict: () -> DATExperimentalPolicy.Verdict
    private let battery: () -> Int?
    private let userAudioPlaying: () -> Bool

    private var connected: [String] = []
    private var deviceId: String?
    private var channel: InputsChannel?
    private var timer: Task<Void, Never>?
    /// Bumped at every start and every stop, so a late callback from an old run is ignored.
    private var run = 0
    private var begun = ContinuousClock.now

    init(source: InputsSource,
         ledger: InputsProbeLedger,
         timeLimit: Duration = InputsProbePolicy.timeLimit,
         verdict: @escaping () -> DATExperimentalPolicy.Verdict,
         battery: @escaping () -> Int?,
         userAudioPlaying: @escaping () -> Bool) {
        self.source = source
        self.ledger = ledger
        self.timeLimit = timeLimit
        self.verdict = verdict
        self.battery = battery
        self.userAudioPlaying = userAudioPlaying
    }

    var isRunning: Bool { phase != .idle }

    /// The devices whose link is connected now. A run whose device leaves stops.
    func update(connectedDeviceIds ids: [String]) {
        connected = ids
        if let deviceId, !ids.contains(deviceId) { stop(.linkDown) }
    }

    /// Begins a run, or says why not. Returns once Inputs is added or has failed.
    @discardableResult
    func start() async -> InputsProbeRefusal? {
        if let refusal = InputsProbePolicy.refusal(verdict: verdict(), connected: !connected.isEmpty,
                                                   running: isRunning) {
            ledger.refused(refusal)
            PrivacyLog.device(.glasses, .inputsProbeRefused, reason: PrivacyToken(refusal.rawValue))
            return refusal
        }
        let id = connected[0]
        run += 1
        let thisRun = run
        deviceId = id
        phase = .starting
        begun = .now
        let level = battery()
        ledger.begin(battery: level)
        PrivacyLog.device(.glasses, .inputsProbeStarted, count: level)
        let timeLimit = timeLimit
        timer = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: timeLimit)) != nil else { return }
            guard let self, self.run == thisRun else { return }
            self.stop(.timeLimit)
        }
        do {
            let opened = try await source.open(deviceId: id, handlers: handlers(for: thisRun))
            guard run == thisRun else {
                // Stopped while Inputs was being added.
                opened.stop()
                return nil
            }
            channel = opened
            // `.active` may have come before the state listener was attached.
            if opened.state == .active { phase = .running }
        } catch {
            guard run == thisRun else { return nil }
            let failure = (error as? InputsProbeFailure) ?? .unknown
            ledger.recordError(failure)
            PrivacyLog.device(.glasses, .inputsProbeError, reason: PrivacyToken(failure.rawValue))
            stop(.failed)
        }
        return nil
    }

    /// Ends the run, if one is going.
    func stop(_ reason: InputsProbeStopReason = .wearerStopped) {
        guard isRunning else { return }
        run += 1
        timer?.cancel()
        timer = nil
        channel?.stop()
        channel = nil
        deviceId = nil
        phase = .idle
        let level = battery()
        ledger.end(reason, battery: level)
        PrivacyLog.device(.glasses, .inputsProbeStopped, reason: PrivacyToken(reason.rawValue),
                          detail: level.map { PrivacyToken("battery\($0)") },
                          count: Int((ContinuousClock.now - begun).components.seconds))
    }

    private func handlers(for thisRun: Int) -> InputsChannelHandlers {
        InputsChannelHandlers(
            onInput: { [weak self] input in
                guard let self, self.run == thisRun else { return }
                let playing = self.userAudioPlaying()
                self.ledger.recordInput(input, userAudioPlaying: playing)
                PrivacyLog.device(.glasses, .inputsProbeInput, state: PrivacyToken(input.kind.reportToken),
                                  detail: PrivacyToken(input.origin.rawValue),
                                  count: self.millisecondsSinceStart(), success: playing)
            },
            onState: { [weak self] state in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordState(state)
                PrivacyLog.device(.glasses, .inputsProbeState, state: PrivacyToken(state.rawValue))
                if state == .active, self.phase == .starting { self.phase = .running }
            },
            onFailure: { [weak self] failure in
                guard let self, self.run == thisRun else { return }
                self.ledger.recordError(failure)
                PrivacyLog.device(.glasses, .inputsProbeError, reason: PrivacyToken(failure.rawValue))
                self.stop(.capabilityFailed)
            },
            onEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.stop(.sessionEnded)
            },
            onInputsEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.stop(.inputsEnded)
            })
    }

    private func millisecondsSinceStart() -> Int {
        let elapsed = ContinuousClock.now - begun
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
