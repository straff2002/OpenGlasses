import Foundation
import Combine

/// Why the band check didn't start (Plan KP §5). The phone page says which, and nothing starts.
enum BandPracticeRefusal: Equatable {
    /// The Glasses Display (HUD) switch is off.
    case hudOff
    /// No display, or the glasses are not connected or not worn (`DisplayAvailability.off`).
    case displayOff
    /// Another app has the Display (`DisplayAvailability.inUse`).
    case displayInUse
    /// A task card is on the lens; the check never takes the HUD from one.
    case taskRunning

    var message: String {
        switch self {
        case .hudOff:
            return String(localized: "Turn on Glasses Display (HUD) to practise the band.")
        case .displayOff:
            return String(localized: "The display isn't available. Connect your display glasses and put them on, then try again.")
        case .displayInUse:
            return String(localized: "Another app is using the display. Close it on the glasses, then try again.")
        case .taskRunning:
            return String(localized: "A task card is on the display. Finish or close it first.")
        }
    }
}

/// Runs the band check on the glasses (Plan KP §5, P3): the **Practise the band** card, its live
/// state for the phone page, and the last run for the support report.
///
/// **Starting.** From Devices & Privacy › Glasses › In-Lens Display, or the launcher's
/// "Practise the band". Refused, with a reason, while the HUD is off, the Display is `.off` or
/// `.inUse`, or a task card is up; an open launcher menu is closed first.
///
/// **Presses.** Every press — the band's, or a test's — is issued against the revision the card was
/// last drawn at (`GlassesDisplayService.heldScreenRevision`) and passes §2's gate first: while a
/// notification is over the card, presses are stale and dropped. Then `BandPractice` judges it by
/// the button's id. A right press plays the accepted tick and redraws the card; a wrong one plays
/// the refused tone and is recorded, not advanced.
///
/// **Ending.** Done on the last screen, Stop on the phone, `idleLifetime` with no press, or the lens
/// taken by something else (a task card, a menu, the HUD ending interactive mode). The check
/// ends interactive mode itself only while its card is the held screen, so it never clears
/// something that replaced it and never leaves the HUD stuck. Every run writes its result to
/// `BandCheckStore` (the last run only): when the last lesson passes, or when the run ends early.
@MainActor
final class BandPracticeSession: ObservableObject {
    /// No press for this long ends the run.
    static let defaultIdleLifetime: TimeInterval = 60

    enum Cue: Equatable { case right, wrong }

    private let display: GlassesDisplayService
    private let store: BandCheckStore

    /// The launcher's router: a task card refuses the start, an open menu is closed first.
    weak var router: HUDRouter?
    /// Plays the press's tone (AppState: the temple taps' accepted and refused tones).
    var playCue: ((Cue) -> Void)?
    /// The display backend's token for the report.
    var backend: () -> String = BandPracticeSession.activeBackendToken

    // MARK: Test seams

    var idleLifetime: TimeInterval = BandPracticeSession.defaultIdleLifetime
    var scheduleIdleTimer: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }
    /// Runs the lens-ownership check after the display has changed (the next main-actor turn in
    /// production, since `objectWillChange` fires before the change lands).
    var deferLensCheck: (@escaping @MainActor () -> Void) -> Void = { check in
        Task { @MainActor in check() }
    }
    var now: () -> Date = Date.init
    /// Called with every press the card's handler receives, and whether it got past the gate.
    var onPressReceived: ((_ id: String, _ accepted: Bool) -> Void)?

    // MARK: State

    /// The run in progress, or nil.
    @Published private(set) var practice: BandPractice?
    /// The last run's result, from the store.
    @Published private(set) var lastResult: BandCheckResult?
    /// Why the last start was refused, until the next start.
    @Published private(set) var refusal: BandPracticeRefusal?

    /// The screen last handed to the display: what a band press acts on.
    private(set) var shownScreen: HUDScreen?
    /// The run's result has been written (the last lesson passed); ending it doesn't write again.
    private var resultSaved = false
    private var idleGeneration = 0
    private var displayWatch: AnyCancellable?

    init(display: GlassesDisplayService, store: BandCheckStore = BandCheckStore()) {
        self.display = display
        self.store = store
        lastResult = store.load()
    }

    var isRunning: Bool { practice != nil }

    /// Whether the check's card is the screen held on the HUD.
    var ownsLens: Bool {
        guard let shownScreen, display.isInteractive, !display.showsAnswerCard else { return false }
        return display.heldScreenRenderKey == shownScreen.renderKey
    }

    static func activeBackendToken() -> String {
        #if !AVENKIN_PHONE_ONLY
        return Config.displayBackend.rawValue
        #else
        return "none"
        #endif
    }

    // MARK: - Start and stop

    /// Start a run. Returns the refusal when it can't start (also published in `refusal`).
    @discardableResult
    func start() -> BandPracticeRefusal? {
        if isRunning { return nil }
        if let reason = startRefusal() {
            refusal = reason
            PrivacyLog.device(.hud, .bandCheckRefused, reason: PrivacyToken(reason.token))
            return reason
        }
        refusal = nil
        if router?.isPresentingMenu == true { router?.dismiss() }
        practice = BandPractice()
        resultSaved = false
        PrivacyLog.device(.hud, .bandCheckStarted, state: PrivacyToken(backend()))
        draw()
        watchDisplay()
        armIdleTimer()
        return nil
    }

    /// Stop on the phone.
    func stop() {
        end(.stopped)
    }

    private func startRefusal() -> BandPracticeRefusal? {
        guard Config.glassesDisplayEnabled else { return .hudOff }
        if router?.isPresentingTask == true { return .taskRunning }
        switch display.practiceAvailability {
        case .ours: return nil
        case .inUse: return .displayInUse
        case .off: return .displayOff
        }
    }

    private func end(_ ending: BandCheckResult.Ending) {
        guard let run = practice else { return }
        idleGeneration += 1
        displayWatch = nil
        let wasOnLens = ownsLens
        practice = nil
        shownScreen = nil
        if !resultSaved { save(run, ending: ending) }
        PrivacyLog.device(.hud, .bandCheckEnded, state: PrivacyToken(ending.rawValue),
                          count: run.lessonsPassed)
        if wasOnLens { display.endInteractive() }
    }

    private func save(_ run: BandPractice, ending: BandCheckResult.Ending) {
        let result = run.result(ending: ending, backend: backend(), at: now())
        store.save(result)
        lastResult = result
        resultSaved = true
    }

    // MARK: - Presses

    /// A press on the card's button `id`, issued against `revision`: dropped when another frame
    /// has been enqueued since (§2), then judged by `BandPractice`.
    func handle(_ id: String, issuedAgainst revision: UInt64) {
        guard isRunning, ownsLens else {
            onPressReceived?(id, false)
            return
        }
        guard display.acceptsHeldScreenPress(issuedAgainst: revision) else {
            practice?.noteStalePress()
            onPressReceived?(id, false)
            return
        }
        onPressReceived?(id, true)
        if id == BandPractice.doneID {
            if practice?.isFinished == true { end(.finished) }
            return
        }
        guard var run = practice else { return }
        let outcome = run.press(id, at: now())
        practice = run
        switch outcome {
        case .stale:
            return
        case .wrong:
            armIdleTimer()
            playCue?(.wrong)
        case .advanced, .lessonPassed:
            armIdleTimer()
            playCue?(.right)
            draw()
        case .finished:
            armIdleTimer()
            playCue?(.right)
            save(run, ending: .finished)
            draw()
        }
    }

    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let self else { return }
            self.handle(id, issuedAgainst: self.display.heldScreenRevision)
        }
    }

    private func draw() {
        guard let run = practice else { return }
        let screen = BandPracticeCardBuilder.screen(for: run, onPress: selectionHandler)
        shownScreen = screen
        display.present(screen: screen, onSelect: selectionHandler)
    }

    // MARK: - Lifetime

    private func armIdleTimer() {
        idleGeneration += 1
        let generation = idleGeneration
        scheduleIdleTimer(idleLifetime) { [weak self] in
            guard let self, generation == self.idleGeneration, self.isRunning else { return }
            self.end(.timedOut)
        }
    }

    /// Follow the display: once something else holds the HUD (or interactive mode ended), the run
    /// is over. It doesn't clear the lens then; whatever replaced the card owns it.
    private func watchDisplay() {
        displayWatch = display.objectWillChange.sink { [weak self] _ in
            self?.deferLensCheck { [weak self] in self?.checkLens() }
        }
    }

    /// The run ends when its card is no longer the held screen.
    func checkLens() {
        // While another app has the Display the card is still the held screen (it is drawn again on
        // return), so this holds only when something replaced it.
        guard isRunning, shownScreen != nil, !ownsLens else { return }
        end(.interrupted)
    }
}

private extension BandPracticeRefusal {
    var token: String {
        switch self {
        case .hudOff: return "hudOff"
        case .displayOff: return "displayOff"
        case .displayInUse: return "displayInUse"
        case .taskRunning: return "taskRunning"
        }
    }
}
