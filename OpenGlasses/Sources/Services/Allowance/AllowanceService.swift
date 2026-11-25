import Combine
import Foundation
import UIKit

/// Where a refusal happened, for whoever tells the user about it.
enum AllowanceRefusalSurface: String, Equatable {
    /// A turn: typed, spoken, Siri, the Watch, CarPlay, a shortcut, the widget or Live Activity.
    case turn
    /// A Live session that could not start, or that closed at zero.
    case live
}

/// Plan NH — the daily allowance on the phone. Applies `DailyAllowancePolicy` and
/// `AllowanceExemption` to the turn path (`LLMService`) and the Live sessions
/// (`RealtimeSessionManager`), and keeps `AssistantTimeLedger` counting.
///
/// Every input is injected: the ledger, the clock, the exemption signals and whether the timers run.
/// The app uses `shared`; a test builds its own over a temporary directory and its own inputs, and
/// drives the meters by calling `tick()` and `liveTick()` itself.
@MainActor
final class AllowanceService: ObservableObject {

    static let shared = AllowanceService(ledger: AssistantTimeLedger(),
                                         inputs: AllowanceService.productionInputs)

    /// Seconds used today, as last read. Drives the Home line and Settings › Subscription.
    @Published private(set) var usedTodaySeconds: Int = 0
    /// Whether the user is exempt right now (ignoring the turn in hand).
    @Published private(set) var isExempt: Bool = true

    let ledger: AssistantTimeLedger
    private let inputs: @MainActor () -> AllowanceExemption.Inputs
    private let now: () -> Date
    private let runsTimers: Bool

    /// Told about a refusal, once per refusal: the phone opens the subscription sheet, or posts a
    /// notification that opens it when the app is not in front. Never waited on.
    var onRefused: ((AllowanceRefusalSurface) -> Void)?
    /// Whether the speech engine is speaking now. AppState: `speechService.isSpeaking`.
    var speechIsActive: () -> Bool = { false }

    // Turns
    private var tracker = TurnChargeTracker()
    /// Nested `sendMessage` calls (a cascade's attempts, a hop after tools) are one turn.
    private var turnDepth = 0
    /// Whether the open turn is counted: an exempt turn never is.
    private var turnCounted = false
    private var turnLoop: Task<Void, Never>?

    // Live
    struct LiveHooks {
        /// The session is connected and ready.
        var isConnected: () -> Bool
        /// An answer is under way: the model speaking, the wearer speaking, a tool call running.
        var answerInProgress: () -> Bool
        /// Say the one warning in the session's own voice.
        var warn: (String) -> Void
        /// Close the session and say the line.
        var close: (String) -> Void
    }
    private var liveHooks: LiveHooks?
    private var liveSession = LiveAllowanceSession()
    private var liveLoop: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?

    var isLiveMetered: Bool { liveHooks != nil }

    init(ledger: AssistantTimeLedger,
         inputs: @escaping @MainActor () -> AllowanceExemption.Inputs,
         now: @escaping () -> Date = { Date() },
         runsTimers: Bool = true) {
        self.ledger = ledger
        self.inputs = inputs
        self.now = now
        self.runsTimers = runsTimers
        refresh()
        if runsTimers {
            refreshLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Reading

    /// Re-read today's seconds and the exemption. Cheap; called by the timers and the screens.
    func refresh() {
        usedTodaySeconds = ledger.secondsUsed(on: now())
        isExempt = AllowanceExemption.isExempt(inputs())
    }

    var remainingSeconds: Int { DailyAllowancePolicy.remaining(usedSeconds: usedTodaySeconds) }

    /// The Home line, or nil when it is hidden: exempt, or nothing run today.
    var homeStatus: DailyAllowancePolicy.HomeStatus? {
        DailyAllowancePolicy.homeStatus(usedSeconds: usedTodaySeconds, exempt: isExempt)
    }

    /// The exemption for a turn saying `utterance`.
    func exemptionInputs(utterance: String?) -> AllowanceExemption.Inputs {
        var current = inputs()
        if let utterance { current.firstAidTurn = FirstAidTurnRecognizer.isFirstAid(utterance) }
        return current
    }

    // MARK: - The turn gate

    /// Whether a turn may go to a model. First aid is checked first, inside the exemption, so an
    /// emergency phrase is never refused, even at zero. A turn already under way (a cascade's next
    /// attempt, a hop after tools) always proceeds: a turn that started under the limit finishes.
    func turnOutcome(utterance: String) -> DailyAllowanceOutcome {
        if turnDepth > 0 { return .proceed }
        let exemption = exemptionInputs(utterance: utterance)
        let exempt = AllowanceExemption.isExempt(exemption)
        let used = ledger.secondsUsed(on: now())
        usedTodaySeconds = used
        switch DailyAllowancePolicy.decide(usedSeconds: used, exempt: exempt) {
        case .proceed:
            return .proceed
        case .proceedWithNotice(let left):
            return .proceedWithNotice(remainingSeconds: left)
        case .exhausted:
            PrivacyLog.model(.dailyAllowance, detail: PrivacyToken("refused"))
            onRefused?(.turn)
            return .answer(DailyAllowancePolicy.exhaustedLine)
        }
    }

    /// A turn was sent to a model. Pair with `turnEnded()`.
    func turnBegan(utterance: String) {
        turnDepth += 1
        guard turnDepth == 1 else { return }
        turnCounted = !AllowanceExemption.isExempt(exemptionInputs(utterance: utterance))
        guard turnCounted else {
            // A counted turn still waiting on its speech ends here; this one is not counted.
            charge(tracker.close(at: now()))
            return
        }
        charge(tracker.begin(at: now()))
        startTurnLoop()
    }

    /// The turn's reply came back (or it failed). Its time stops when the reply has been spoken,
    /// or, if nothing speaks it, now.
    func turnEnded() {
        guard turnDepth > 0 else { return }
        turnDepth -= 1
        guard turnDepth == 0, turnCounted else { return }
        tracker.replyReturned(at: now(), speaking: speechIsActive())
    }

    private var speechObservation: AnyCancellable?
    private var refreshTriggers: [AnyCancellable] = []

    /// Re-read the exemption whenever `trigger` fires — a purchase, a restore, a licence — so a new
    /// subscriber's counter goes at once. Read on the next turn of the main queue, after the change.
    func refresh(whenever trigger: AnyPublisher<Void, Never>) {
        refreshTriggers.append(trigger.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() })
    }

    /// Follow the speech engine, so a spoken reply's time ends when it stops speaking.
    func observeSpeech(_ speaking: AnyPublisher<Bool, Never>, current: @escaping () -> Bool) {
        speechIsActive = current
        speechObservation = speaking.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.speechActivityChanged(active) }
    }

    /// The speech engine started or stopped.
    func speechActivityChanged(_ active: Bool) {
        charge(tracker.speech(active: active, at: now()))
    }

    /// Advance the turn meter. The app's loop calls it twice a second; tests call it by hand.
    func tick() {
        charge(tracker.tick(at: now()))
        if tracker.isIdle { turnLoop?.cancel(); turnLoop = nil }
    }

    private func charge(_ seconds: Int?) {
        guard let seconds, seconds > 0 else { return }
        let at = now()
        ledger.add(seconds, at: at)
        usedTodaySeconds = ledger.secondsUsed(on: at)
        PrivacyLog.model(.dailyAllowance, seconds: Double(seconds), detail: PrivacyToken("turnCharged"))
    }

    private func startTurnLoop() {
        guard runsTimers, turnLoop == nil else { return }
        turnLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    // MARK: - The Live gate

    /// Why a Live session may not connect, or nil. A session already metered may always reconnect:
    /// its grace and close are the meter's to decide.
    func liveConnectRefusal() -> String? {
        guard liveHooks == nil else { return nil }
        let exempt = AllowanceExemption.isExempt(exemptionInputs(utterance: nil))
        let used = ledger.secondsUsed(on: now())
        usedTodaySeconds = used
        guard DailyAllowancePolicy.decide(usedSeconds: used, exempt: exempt) == .exhausted else { return nil }
        PrivacyLog.model(.dailyAllowance, detail: PrivacyToken("liveRefused"))
        onRefused?(.live)
        return DailyAllowancePolicy.exhaustedLine
    }

    /// A Live session connected: count every second it stays connected.
    func startLiveMeter(_ hooks: LiveHooks) {
        stopLiveMeter()
        liveHooks = hooks
        liveSession = LiveAllowanceSession()
        guard runsTimers else { return }
        liveLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.liveTick()
            }
        }
    }

    /// The session ended.
    func stopLiveMeter() {
        liveLoop?.cancel()
        liveLoop = nil
        liveHooks = nil
        ledger.flush()
    }

    /// One second of a Live session. The app's loop calls it once a second; tests call it by hand.
    func liveTick() {
        guard let hooks = liveHooks else { return }
        let at = now()
        let exempt = AllowanceExemption.isExempt(exemptionInputs(utterance: nil))
        isExempt = exempt
        // Subscribing mid-session lifts the limit at once; an exempt second is never counted.
        guard !exempt else { return }
        if hooks.isConnected() {
            ledger.add(1, at: at, immediately: false)
        }
        let used = ledger.secondsUsed(on: at)
        usedTodaySeconds = used
        let effects = liveSession.tick(remainingSeconds: DailyAllowancePolicy.remaining(usedSeconds: used),
                                       answerInProgress: hooks.answerInProgress(), now: at)
        for effect in effects {
            switch effect {
            case .warn:
                PrivacyLog.model(.dailyAllowance, detail: PrivacyToken("liveWarned"))
                hooks.warn(DailyAllowancePolicy.liveWarningLine)
            case .close:
                PrivacyLog.model(.dailyAllowance, detail: PrivacyToken("liveClosed"))
                stopLiveMeter()
                hooks.close(DailyAllowancePolicy.exhaustedLine)
                onRefused?(.live)
            }
        }
    }

    // MARK: - Production signals

    /// The install channel, read once: it cannot change while the app runs.
    private static let isStoreBuild = AppBuildIdentity.current.channel == .appStore

    /// What the app reads for the exemption. Only `shared` uses this; tests pass their own.
    static func productionInputs() -> AllowanceExemption.Inputs {
        let store = StoreKitService.shared
        var inputs = AllowanceExemption.Inputs()
        inputs.standardActive = store.standardSubscription != nil
        inputs.myManualsActive = store.myManualsSubscription != nil
        inputs.fieldAssistGranted = FieldAssistEntitlement.shared.isGranted
        inputs.medicalActive = store.isMedicalComplianceActive
        inputs.organisationProfile = PolicyEnvelope.isManaged
        inputs.purchasesUnread = !store.hasCheckedEntitlements
        inputs.voiceOverRunning = UIAccessibility.isVoiceOverRunning
        inputs.accessibilityModeOn = Config.accessibilityModeEnabled
        inputs.assistiveModeActive = AssistiveModeService.shared.isActive
            || Config.activeLiveAIModeId == BlindAssistanceContract.presetID
        inputs.firstAidSessionActive = FirstAidAssistService.shared.isActive
        inputs.isStoreBuild = isStoreBuild
        inputs.meterAsStoreBuild = Config.meterAsStoreBuild
        return inputs
    }
}

/// The Live connect gate, for the sockets themselves (`GeminiLiveService.connect()`,
/// `RealtimeJSONSessionService.connect()`, which Doubao's and every other JSON protocol's sessions
/// open through, and `OpenAIRealtimeService.connect()`). `RealtimeSessionManager` checks first and
/// says the line; this is the backstop for any other path to a socket.
@MainActor
enum LiveAllowanceGate {
    /// AppState sets this to the allowance service. Nil — a test, a preview — admits every connect.
    static var refusal: (() -> String?)?

    static func check() -> String? { refusal?() }
}
