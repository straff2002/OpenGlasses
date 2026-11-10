import Foundation

/// Mirrors short content to the in-lens HUD through the active `GlassesDisplayBackend`
/// (Plan AH): Ray-Ban Display via the DAT SDK (`MetaDisplayBackend`, default) or EVEN
/// Realities G2 over BLE (`EvenDisplayBackend`).
///
/// Producers wired so far:
/// - Phase 1: AI responses (`TextToSpeechService`) and the live ambient-caption line.
/// - Phase 2: notifications (proactive/calendar + geofence alerts) and Navigation
///   Assist guidance, rendered with an icon + heading + body.
///
/// Everything is additive — the on-phone overlay and TTS are untouched. When the active
/// backend reports no display, every call is a safe no-op and no transport is created.
///
/// This service owns everything backend-neutral: the latest-wins render queue, dedup,
/// the interactive gate (Plan X), flash-then-restore, and text condensing
/// (`HUDTextShaper`). Backends own capability, transport lifecycle, and the
/// content→device mapping. The backend choice governs the DISPLAY only — camera/audio
/// run on their own services, so a Meta camera + EVEN HUD hybrid works by construction.
@MainActor
final class GlassesDisplayService: ObservableObject {
    /// True once the display transport is active and content is being shown.
    @Published private(set) var isDisplayActive = false
    /// Whether the currently-active backend reports an in-lens display.
    @Published private(set) var hasDisplayCapability = false

    /// Debug event callback (wired to `AppState.addDebugEvent`).
    var onDebugEvent: ((String) -> Void)?

    /// Kept as a nested alias — `HUDIcon` moved next to the DSL (Plan AH); existing
    /// `GlassesDisplayService.HUDIcon` references stay valid.
    typealias HUDIcon = OpenGlasses.HUDIcon

    /// A single HUD frame: optional heading + body, with an optional leading icon.
    private struct HUDContent: Equatable {
        var title: String?
        var body: String
        var icon: HUDIcon
    }

    private enum RenderOp: Equatable {
        case show(HUDContent)
        case clear
    }

    /// A unit of work for the render queue: an ambient content/clear op, or a full
    /// interactive screen (Plan X). Screens carry closures, so they're deduped by
    /// `renderKey` rather than `Equatable`.
    private enum Frame {
        case op(RenderOp)
        case screen(HUDScreen)
    }

    // MARK: - Backends (Plan AH)

    #if !AVENKIN_PHONE_ONLY
    private lazy var metaBackend: MetaDisplayBackend = {
        let backend = MetaDisplayBackend()
        wire(backend)
        return backend
    }()

    private lazy var evenBackend: EvenDisplayBackend = {
        let backend = EvenDisplayBackend()
        wire(backend)
        return backend
    }()

    /// The backend the config selects. Resolved per call — switching backends in
    /// Settings takes effect on the next render.
    private var activeBackend: GlassesDisplayBackend {
        switch Config.displayBackend {
        case .metaRayBan: return metaBackend
        case .evenG2: return evenBackend
        }
    }

    #else
    private let activeBackend: GlassesDisplayBackend = UnsupportedGlassesDisplayBackend()
    #endif

    private func wire(_ backend: GlassesDisplayBackend) {
        backend.onItemSelected = { [weak self] id in
            self?.screenSelectionHandler?(id)
        }
        backend.onTransportError = { [weak self] error in
            self?.handleRenderError(error)
        }
        #if !AVENKIN_PHONE_ONLY
        if let meta = backend as? MetaDisplayBackend {
            meta.onDebugEvent = { [weak self] message in self?.onDebugEvent?(message) }
            meta.onSessionReading = { [weak self] reading in self?.applySessionReading(reading) }
            meta.onSessionEndedByDevice = { [weak self] in self?.lensEndedByDevice() }
        }
        #endif
    }

    /// Latest-wins render queue. Rapid updates collapse to the most recent frame so we
    /// never flood the link — only one `send` is ever in flight.
    private var pending: Frame?
    private var isRendering = false
    /// The ambient op last pushed to the HUD; identical follow-ups are skipped.
    private var lastRendered: RenderOp?
    /// The interactive screen last pushed (by `renderKey`); identical screens are skipped.
    private var lastScreenKey: String?

    /// Generation guard for transient auto-clear, so a newer frame cancels an older
    /// frame's pending clear.
    private var autoClearGeneration = 0

    // MARK: - Interactive (Plan X)

    /// True while an interactive screen (task card / menu) is held on the HUD. Ambient
    /// *persistent* producers (AI replies, captions, navigation) are suppressed while
    /// set; transient notifications flash over the screen and then restore it.
    @Published private(set) var isInteractive = false

    /// Plan BP: the last frame the queue resolved, as a screen — the web mirror's
    /// read-only source (`hud.json`). Ambient content wraps into a lines-only screen;
    /// nil = cleared. Updated even in mirror-only mode (no native display available),
    /// which is the entitlement-free story: producers render, the backend send is skipped.
    @Published private(set) var mirrorScreen: HUDScreen?
    private var currentScreen: HUDScreen?
    private var screenSelectionHandler: ((String) -> Void)?

    // MARK: - Answer cards and stale frames (Plan KP P1)

    /// Bumped by every frame the render queue is handed: an ambient op, a screen, a clear, an
    /// answer card's page (§2). A page turn or a card action carries the revision it was issued
    /// against, and `PageTurnGate` drops it when anything was enqueued since, so a notification
    /// that arrived between "next" and the page render wins.
    private(set) var frameRevision: UInt64 = 0

    /// The revision at which the held interactive screen was last handed to the queue — the
    /// frame whose buttons a band press (or a spoken or tapped page turn) acts on. A press is
    /// issued against this, so a notification enqueued over the card makes it stale until the
    /// card is drawn again (the flash's restore, or the card's next change).
    private(set) var heldScreenRevision: UInt64 = 0

    /// True while the held interactive screen is an answer card (`HUDAnswerCard`) rather than a
    /// task card, a menu or a choice list. An answer only becomes a card while this is true or
    /// nothing interactive is up: over anything else it flashes, as it always has.
    @Published private(set) var showsAnswerCard = false

    /// A transient frame (a notification, a flash) is drawn over the held interactive screen and
    /// will restore it. A card that changes meanwhile updates `currentScreen` only, so the restore
    /// draws the newest version instead of the card cutting the notification short.
    private var flashingOverInteractive = false

    /// The transient frame (a notification, a flash) last handed to the queue, until its auto-clear
    /// runs or another frame replaces it. Plan KV P1 fix: a page view opened while one is showing
    /// with nothing interactive under it goes under the notification, as it would over a held
    /// card, and the notification's auto-clear draws it — rather than the view cutting it short.
    private var transientShowing: RenderOp?

    /// Whether an answer may be shown as a card right now: the HUD is on, something can show it
    /// (a display or the mirror), and nothing but an answer card is held. Plan KV: a page's
    /// **Show here** cue gives way to an answer like a card does; an open page view takes the
    /// answer under it (shown when the view closes) unless it was opened over a task card or a menu.
    /// Plan KX §4: the turn's Listening or Thinking card is waiting for exactly this answer, so it
    /// gives way too. An approval card does not: the answer flashes over it, as over a task card.
    var acceptsAnswerCard: Bool {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return false }
        switch heldPage {
        case .cue: return true
        case .view: return pageTakesAnswerUnder
        case nil: return !isInteractive || showsAnswerCard || showsTurnState
        }
    }

    // MARK: - Listening and Thinking (Plan KX §4)

    /// True while the held interactive screen is the wearer's turn in progress — the Listening card
    /// (the live partial transcript) or the Thinking card — put up by `HUDTurnState`. The answer
    /// card replaces it; anything else that takes the lens (a menu, a task card, a page view, an
    /// approval card, guidance) ends it.
    @Published private(set) var showsTurnState = false

    /// Whether the turn's Listening or Thinking card may go up now: the HUD is on, something can show
    /// it, the lens is ours, and nothing but an answer card (or the turn's own card) is held. Never
    /// over a task card, a menu, a page view or an approval card: those are the wearer's work, and a
    /// turn spoken over them is about them.
    var acceptsTurnState: Bool {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled, !holdsLens else { return false }
        guard !showsApprovalCard, heldPage == nil else { return false }
        return !isInteractive || showsAnswerCard || showsTurnState
    }

    /// Hold the turn's Listening or Thinking card (Plan KX §4), or redraw it. `wearerStarted`: the
    /// wearer just started this turn (the wake word, a tap, the Action Button), which is wearer-led
    /// and so reopens a lens they dismissed (§2.2). A later update to the same turn (a partial, the
    /// Thinking card) is not, and stays off a lens dismissed meanwhile. While a notification is over
    /// the card, only the held screen changes and the notification's restore draws it. False — and
    /// nothing changes — when `acceptsTurnState` is false.
    @discardableResult
    func presentTurnState(_ screen: HUDScreen, wearerStarted: Bool,
                          onSelect: @escaping (String) -> Void) -> Bool {
        guard acceptsTurnState else { return false }
        if lensDismissed {
            guard wearerStarted else { return false }
            wearerLed()
        }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = false
        showsTurnState = true
        if !flashingOverInteractive { enqueue(.screen(screen)) }
        return true
    }

    /// The turn ended without an answer card replacing its Listening or Thinking card (nothing was
    /// heard, the turn failed, a command answered it by voice): the card clears. A line the turn
    /// spoke that is flashing over it (an error, "Didn't catch that") finishes first, and its own
    /// auto-clear clears the lens. Under an approval card, the card is simply not restored.
    func endTurnState() {
        if showsApprovalCard {
            if underApproval?.showsTurnState == true { underApproval = nil }
            return
        }
        guard showsTurnState else { return }
        showsTurnState = false
        guard !flashingOverInteractive else {
            isInteractive = false
            currentScreen = nil
            screenSelectionHandler = nil
            flashingOverInteractive = false
            onDebugEvent?("HUD turn state ended under a flash")
            return
        }
        endInteractive()
    }

    // MARK: - Approve / Deny (Plan KX §3)

    /// True while an approval card (`HUDApprovalCard`) is held over whatever the lens had.
    @Published private(set) var showsApprovalCard = false

    /// What the lens held when an approval card went up, restored when it is answered. Everything
    /// that says what the held screen is, so a task card, a menu, an answer card, the turn's card or
    /// a page view comes back as it was.
    private struct HeldUnderApproval {
        var screen: HUDScreen
        var handler: ((String) -> Void)?
        var showsAnswerCard: Bool
        var showsTurnState: Bool
        var heldPage: HeldPage?
        var answerUnderPage: (screen: HUDScreen, onSelect: (String) -> Void)?
        var pageTakesAnswerUnder: Bool
    }
    private var underApproval: HeldUnderApproval?

    /// Whether an approval may be asked on the lens: the HUD is on, something can show it, the lens
    /// is ours, and the wearer has not dismissed it. An approval is not wearer-led — the assistant
    /// asked — so it does not reopen a dismissed lens; the prompt is still spoken and on the phone.
    var acceptsApprovalCard: Bool {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return false }
        return !holdsLens && !lensDismissed
    }

    /// Hold an approval card over whatever the lens has (Plan KX §3), or redraw the one held (its
    /// Details screen and back). The held screen underneath is kept, and comes back when
    /// `endApprovalCard()` runs. While it is up, a task card or menu that changes (or opens) goes
    /// underneath it, an answer flashes over it, and a page view does not open. False when
    /// `acceptsApprovalCard` is false and no approval card is held.
    @discardableResult
    func presentApprovalCard(_ screen: HUDScreen, onSelect: @escaping (String) -> Void) -> Bool {
        if showsApprovalCard {
            screenSelectionHandler = onSelect
            currentScreen = screen
            if !flashingOverInteractive { enqueue(.screen(screen)) }
            return true
        }
        guard acceptsApprovalCard else { return false }
        if isInteractive, let held = currentScreen {
            underApproval = HeldUnderApproval(screen: held, handler: screenSelectionHandler,
                                              showsAnswerCard: showsAnswerCard,
                                              showsTurnState: showsTurnState,
                                              heldPage: heldPage, answerUnderPage: answerUnderPage,
                                              pageTakesAnswerUnder: pageTakesAnswerUnder)
        } else {
            underApproval = nil
        }
        showsApprovalCard = true
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = false
        showsTurnState = false
        heldPage = nil
        answerUnderPage = nil
        pageTakesAnswerUnder = false
        // An approval is drawn at once, over a notification too: the wearer is being asked now.
        flashingOverInteractive = false
        onDebugEvent?("HUD approval card")
        enqueue(.screen(screen))
        return true
    }

    /// The approval was answered (any way: the band, voice, the phone) or timed out: what was held
    /// under it comes back, or the lens clears. A notification flashing over the card finishes
    /// first, and its restore draws what came back.
    func endApprovalCard() {
        guard showsApprovalCard else { return }
        showsApprovalCard = false
        let under = underApproval
        underApproval = nil
        guard let under else {
            isInteractive = false
            currentScreen = nil
            screenSelectionHandler = nil
            if flashingOverInteractive {
                flashingOverInteractive = false
            } else {
                enqueue(.op(.clear))
            }
            onDebugEvent?("HUD approval card ended")
            return
        }
        currentScreen = under.screen
        screenSelectionHandler = under.handler
        isInteractive = true
        showsAnswerCard = under.showsAnswerCard
        showsTurnState = under.showsTurnState
        heldPage = under.heldPage
        answerUnderPage = under.answerUnderPage
        pageTakesAnswerUnder = under.pageTakesAnswerUnder
        if !flashingOverInteractive { enqueue(.screen(under.screen)) }
        onDebugEvent?("HUD approval card ended; restored what was under it")
        // An answer card's lifetime starts over, as after the page view: the wearer was answering
        // the approval, not ignoring the answer.
        if under.showsAnswerCard { onAnswerCardReturnedFromPage?() }
    }

    // MARK: - The page on the lens (Plan KV)

    /// What a page screen on the lens is: the page view itself, or the one-button **Show here** cue
    /// for a page the app put up by itself.
    enum HeldPage: Equatable {
        case view
        case cue
    }

    /// The page screen held on the lens, if one is. Set by `presentPageView`; cleared by anything
    /// else taking the HUD.
    @Published private(set) var heldPage: HeldPage?
    /// The answer card the page view was opened over, or that arrived while it was up: what Close
    /// returns to. Its screen is kept current while the view is up.
    private var answerUnderPage: (screen: HUDScreen, onSelect: (String) -> Void)?
    /// The page view was opened over nothing or an answer card, so an answer can wait under it. Over
    /// a task card or a menu, an answer flashes, as it does over them.
    private var pageTakesAnswerUnder = false

    /// An answer card is held under the page view, to come back when it closes.
    var holdsAnswerCardUnderPage: Bool { answerUnderPage != nil }

    /// Set by `HUDAnswerCard`: the page view (or, Plan KX §3, an approval card) closed and the answer
    /// card under it is on the lens again.
    var onAnswerCardReturnedFromPage: (() -> Void)?

    /// Called after a screen carrying a picture reached the backend: the bytes the backend says it
    /// sent (nil when it cannot say) and how long the send took. For the support report.
    var onPictureSent: ((_ bytes: Int?, _ milliseconds: Int) -> Void)?

    /// Test seam: whether the backend draws pictures, without constructing it.
    var testDrawsPicturesOverride: Bool?

    /// Plan KV §6: whether the active backend draws a screen's picture (Meta Display) or only its
    /// text lines (Even G2; the phone-only build).
    var drawsPictures: Bool { testDrawsPicturesOverride ?? activeBackend.drawsPictures }

    /// Plan KX §5: whether a vision answer's thumbnail is worth drawing now — the HUD is on, a
    /// display is there and its backend draws pictures. Read before the phone spends a decode on it.
    var wantsAnswerPictures: Bool {
        isEnabled && drawsPictures && deviceSupportsDisplay()
    }

    /// Hold a page screen on the lens (Plan KV §4): the page view or its cue. Not a press, so not
    /// gated; while a notification is showing — over a held screen or over nothing — the screen is
    /// held and the notification's auto-clear draws it, so the notification stays up for its full
    /// duration. A press on the view before then is stale (`heldScreenRevision` is older than the
    /// notification) and is dropped, as one made under a notification always is. False — and nothing changes — while the HUD is off, there is no display,
    /// or another app has the Display (KP §8: the lens is not taken back).
    @discardableResult
    func presentPageView(_ screen: HUDScreen, kind: HeldPage, onSelect: @escaping (String) -> Void) -> Bool {
        guard isEnabled, deviceSupportsDisplay(), !holdsLens else { return false }
        // Plan KX §3: an approval card is being answered; nothing opens over it.
        guard !showsApprovalCard else { return false }
        // Plan KX §2.2: a page the wearer opened reopens a dismissed lens; a cue the app put up does not.
        if kind == .view { wearerLed() } else if lensDismissed { return false }
        if kind == .view {
            switch heldPage {
            case .view:
                break   // the next page of the same view: what is under it stays
            case .cue:
                answerUnderPage = nil
                pageTakesAnswerUnder = true
            case nil:
                if showsAnswerCard, let held = currentScreen, let handler = screenSelectionHandler {
                    answerUnderPage = (held, handler)
                } else {
                    answerUnderPage = nil
                }
                // Plan KX §4: the turn's own card is waiting for an answer, as nothing would be.
                pageTakesAnswerUnder = !isInteractive || showsAnswerCard || showsTurnState
            }
        } else {
            // A cue replaces what it covers, as an answer card does.
            answerUnderPage = nil
            pageTakesAnswerUnder = false
        }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = false
        showsTurnState = false
        heldPage = kind
        if transientShowing != nil { flashingOverInteractive = true }
        if !flashingOverInteractive { enqueue(.screen(screen)) }
        return true
    }

    /// Plan KV §4: the page view's next frame after a press issued against `revision`. Drawn only
    /// when nothing has been enqueued since (`PageTurnGate`); otherwise dropped and logged, so a
    /// notification that arrived between "zoom in" and the render wins.
    @discardableResult
    func updatePageView(_ screen: HUDScreen, issuedAgainst revision: UInt64,
                        onSelect: @escaping (String) -> Void) -> Bool {
        guard heldPage != nil, acceptsHeldScreenPress(issuedAgainst: revision) else { return false }
        screenSelectionHandler = onSelect
        currentScreen = screen
        flashingOverInteractive = false
        enqueue(.screen(screen))
        return true
    }

    /// The page view (or cue) closed with nothing but an answer card, or nothing, under it: the card
    /// comes back if one is held, else interactive mode ends.
    func endPageView() {
        guard heldPage != nil else { return }
        heldPage = nil
        pageTakesAnswerUnder = false
        guard let under = answerUnderPage else {
            endInteractive()
            return
        }
        answerUnderPage = nil
        screenSelectionHandler = under.onSelect
        currentScreen = under.screen
        isInteractive = true
        showsAnswerCard = true
        flashingOverInteractive = false
        enqueue(.screen(under.screen))
        onAnswerCardReturnedFromPage?()
    }

    /// The page view closed over a task card or a menu, which its owner redraws.
    func releasePageView() {
        heldPage = nil
        answerUnderPage = nil
        pageTakesAnswerUnder = false
    }

    /// The answer card held under the page view closed (its lifetime, a new card): Close returns
    /// to nothing.
    func dropAnswerCardUnderPage() {
        answerUnderPage = nil
    }

    /// Plan KP P2: what would show an answer's suggested follow-ups now, for `FollowUpPrompt`. A
    /// display with the HUD on wins over the mirror; the mirror counts only without one.
    var answerSurface: FollowUpPrompt.Surface {
        guard isEnabled else { return .none }
        if deviceSupportsDisplay() { return .display }
        return Config.hudMirrorEnabled ? .mirrorOnly : .none
    }

    // MARK: - When the Display is in use (Plan KP P1b)

    /// Whose the Display is (§8): `.ours`, `.inUse` (another app has it) or `.off`. Read from the
    /// Meta session (`applySessionReading`), the link and worn state (`updateGlassesLink`). The Even
    /// backend and the phone-only build always read `.ours`.
    ///
    /// While `.inUse` nothing is handed to the render queue, so nothing queues for the lens and the
    /// session is never asked to start: notifications and captions are dropped (they were spoken,
    /// or they are live), and the web mirror holds its last frame too. The service keeps state
    /// only: the answer card (`HUDAnswerCard`), or a task card or menu that is still running. When
    /// the reading is `.ours` again the lens is drawn once from that state: a task card or menu as
    /// it now is, the answer card if it is still fresh (`onLensReturnedToAnswerCard`), else a
    /// clear. `.off` changes nothing about rendering; it only means no busy hint.
    @Published private(set) var displayAvailability: DisplayAvailability = .off

    /// What the Meta session last reported (state, refused start).
    private(set) var sessionReading = DisplaySessionReading()
    private var glassesConnected = false
    private var glassesWorn: Bool?
    /// Something was held back from the lens while it was not ours, so it is redrawn on return.
    private var lensMissedFrames = false
    private var busyHint = DisplayBusyHint()
    /// Each change of reading, for the support report.
    private(set) var availabilityLog = DisplayAvailabilityLog()
    /// Test seam: the clock the log stamps with.
    var now: () -> Date = Date.init

    /// Set by `HUDAnswerCard`: the lens is ours again and an answer card is held. The card shows
    /// itself again if it is still inside its lifetime, or closes.
    var onLensReturnedToAnswerCard: (() -> Void)?

    /// While another app has the Display, nothing is enqueued for the lens.
    private var holdsLens: Bool { displayAvailability == .inUse }

    // MARK: - A session the glasses ended (Plan KX §2.2)

    /// True after the glasses ended our display session themselves — the band's Back gesture, a
    /// two-finger temple tap, or the hands-free mic coming up. The wearer dismissed the lens, so
    /// nothing ambient (a caption, a notification, a guidance line, a page's **Show here** cue)
    /// reopens it: every frame is dropped at `enqueue` while this is set. A wearer-led frame clears
    /// it first — a menu or task card presented, a new answer card, a page view opened, the HUD
    /// switch or the display offer's **Turn on**, or the glasses' link coming up again.
    @Published private(set) var lensDismissed = false
    /// The answer card on the lens when it was dismissed: its later growth is not a new answer and
    /// does not reopen the lens.
    private var dismissedAnswerCard: Int?

    /// The glasses ended the session. State only: nothing is sent (the session is gone, and a send
    /// would open a new one). A running task card stays resumable from the launcher.
    func lensEndedByDevice() {
        guard !lensDismissed else { return }
        dismissedAnswerCard = showsAnswerCard ? currentScreen?.pageSet?.card : nil
        lensDismissed = true
        pending = nil
        isInteractive = false
        showsAnswerCard = false
        showsTurnState = false
        showsApprovalCard = false
        underApproval = nil
        flashingOverInteractive = false
        releasePageView()
        currentScreen = nil
        screenSelectionHandler = nil
        transientShowing = nil
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
        sendPacer.reset()
        onDebugEvent?("HUD dismissed by the wearer")
    }

    /// The wearer turned the HUD on (Settings, or the display offer's **Turn on**).
    func wearerTurnedLensOn() {
        wearerLed()
    }

    /// A wearer-led frame is about to be enqueued: the lens may open again.
    private func wearerLed() {
        guard lensDismissed else { return }
        lensDismissed = false
        dismissedAnswerCard = nil
        onDebugEvent?("HUD reopened by the wearer")
    }

    /// The glasses' link and worn state, from `GlassesConnectionService` (`isConnected`, which is
    /// `linkState == .connected`, and `isWorn`).
    func updateGlassesLink(connected: Bool, worn: Bool?) {
        guard connected != glassesConnected || worn != glassesWorn else { return }
        // Plan KX §2.2: a link coming up is a fresh start; a dismissal does not outlive it.
        if connected && !glassesConnected { wearerLed() }
        glassesConnected = connected
        glassesWorn = worn
        refreshAvailability()
    }

    /// What the Meta display session says. Internal so tests can drive the reading without DAT.
    func applySessionReading(_ reading: DisplaySessionReading) {
        guard reading != sessionReading else { return }
        sessionReading = reading
        refreshAvailability()
    }

    /// Plan KP §8 rule 5: whether the busy hint plays after a line from `source` (only an answer),
    /// spoken while the display is `.inUse`, with speech not suppressed and the setting on. Once
    /// per stretch of `.inUse`: taking it uses it up.
    func claimBusyHint(afterLineFrom source: SpeechSource, speechSuppressed: Bool) -> Bool {
        busyHint.claim(availability: displayAvailability,
                       isAnswer: HUDAnswerCard.takesAnswers(from: source),
                       speechSuppressed: speechSuppressed,
                       enabled: Config.displayBusyHintEnabled)
    }

    private var readsSessionAvailability: Bool {
        #if !AVENKIN_PHONE_ONLY
        return Config.displayBackend == .metaRayBan
        #else
        return false
        #endif
    }

    private func currentAvailability() -> DisplayAvailability {
        guard readsSessionAvailability else { return .ours }
        return DisplayAvailability.read(hasDisplay: deviceSupportsDisplay(), connected: glassesConnected,
                                        worn: glassesWorn, session: sessionReading)
    }

    private func refreshAvailability() {
        let next = currentAvailability()
        guard next != displayAvailability else { return }
        displayAvailability = next
        busyHint.readingChanged(to: next)
        availabilityLog.record(next, session: sessionReading, at: now())
        PrivacyLog.device(.hud, .availabilityRead, state: PrivacyToken(next.rawValue),
                          detail: PrivacyToken(sessionReading.token))
        onDebugEvent?("HUD display \(next.rawValue) (\(sessionReading.token))")
        switch next {
        case .inUse: lensMissedFrames = true
        case .ours: if lensMissedFrames { resumeLens() }
        case .off: break
        }
    }

    /// The lens is ours again after another app had it: draw it once from what is held now. No
    /// backlog: what was dropped stays dropped.
    private func resumeLens() {
        lensMissedFrames = false
        // What is on the lens now is not known; nothing is skipped as "already shown".
        lastRendered = nil
        lastScreenKey = nil
        flashingOverInteractive = false
        guard isEnabled else { return }
        if showsAnswerCard, let onLensReturnedToAnswerCard {
            onLensReturnedToAnswerCard()
        } else if isInteractive, let currentScreen {
            enqueue(.screen(currentScreen))
        } else {
            enqueue(.op(.clear))
        }
    }

    /// Plan KP P3: whose the Display is for the band check, read now rather than from the last
    /// change: `.off` while the HUD is off or there is no display (the mirror has no band).
    var practiceAvailability: DisplayAvailability {
        guard isEnabled, deviceSupportsDisplay() else { return .off }
        return currentAvailability()
    }

    /// The held interactive screen's `renderKey`, so a holder (the band check) can tell its own
    /// screen is still the one on the HUD. Nil when none is held.
    var heldScreenRenderKey: String? { isInteractive ? currentScreen?.renderKey : nil }

    /// The support report's lines about the reading.
    var availabilityReportLines: [String] {
        var lines = ["Display reading now: \(displayAvailability.reportName) (\(sessionReading.reportName))"]
        if lensDismissed { lines.append("Display dismissed by the wearer (not reopened for ambient frames)") }
        if let lastSend { lines.append(lastSend.reportLine) }
        return lines + availabilityLog.reportLines()
    }

    // MARK: - Pacing and send records (Plan KX §2.4)

    /// Spaces real sends to the glasses. Not consulted when `testRenderSink` captures frames.
    private var sendPacer = HUDSendPacer()
    /// The last send to the backend, for the support report and the Developer panel.
    @Published private(set) var lastSend: HUDSendRecord?
    /// Test seam: the pacer's sleep (production sleeps on the main actor).
    var paceSleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// A send to the backend ended: note it for the pacer and the report. Nil kind: nothing was sent.
    private func recordSend(_ kind: HUDSendRecord.Kind?, started: ContinuousClock.Instant,
                            outcome: HUDSendRecord.Outcome) {
        guard let kind else { return }
        sendPacer.sent(endingAt: Date(), hadPicture: kind == .picture)
        lastSend = HUDSendRecord(kind: kind, milliseconds: Self.milliseconds(since: started), outcome: outcome)
    }

    /// Plan KX §2.4: whether a failed picture frame is worth sending again as text. Not when there is
    /// no display, or the Display is another app's: those are readings, and text would fail the same.
    static func retriesWithoutPicture(after error: Error) -> Bool {
        if case GlassesDisplayError.noDisplay = error { return false }
        if case GlassesDisplayError.displayInUse = error { return false }
        return true
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Testing seam
    //
    // No display hardware is available in CI/sim, so the interactive logic (capability
    // gate, ambient suppression, render-key dedup, flash-then-restore) is validated
    // headlessly. `testCapabilityOverride` bypasses the backend capability check;
    // `testRenderSink`, when set, captures the frame the queue *would* send instead of
    // hitting a backend. Both are nil in production — the real paths are untouched. The
    // Neural Band itself is simulated in tests by invoking the `onClick` of the buttons
    // produced by `MetaDisplayBackend.makeScreenView(_:)`.
    var testCapabilityOverride: Bool?
    var testRenderSink: ((HUDFrame) -> Void)?

    /// A frame the render queue resolved to — the test observation point.
    enum HUDFrame: Equatable {
        case content(body: String, title: String?, icon: HUDIcon)
        case screen(renderKey: String)
        case clear
    }

    // MARK: - Capability

    /// Whether the active backend exposes an in-lens display. Cheap, synchronous, and
    /// safe to call frequently. Updates `hasDisplayCapability` as a side effect.
    @discardableResult
    func deviceSupportsDisplay() -> Bool {
        // The Meta bootstrap cannot protect the separate EVEN BLE backend. A saved backend and
        // pairing from TestFlight must not start a glasses transport after an App Store upgrade.
        let supported = GlassesSupportPolicy.isSupported && (testCapabilityOverride ?? activeBackend.isAvailable)
        if hasDisplayCapability != supported { hasDisplayCapability = supported }
        // Plan KX §2.5: whether a Meta Display is there to lose to the glasses' hands-free mic.
        LensMicPolicy.metaDisplayPresent = supported && readsSessionAvailability
        return supported
    }

    private var isEnabled: Bool { Config.glassesDisplayEnabled }

    // MARK: - Public API

    /// Show a concise line of body text. No-op when the feature is off or the glasses
    /// have no display. Used by the Phase 1 producers (AI replies, ambient captions).
    ///
    /// `flashWhileInteractive`: when a task card is held, AI replies pass `true` so the
    /// reply briefly flashes over the card and the card is then restored — rather than
    /// being suppressed. Ambient captions leave it `false` (suppressed while a card is
    /// up, to avoid spamming the task).
    func showText(_ text: String, flashWhileInteractive: Bool = false) {
        if flashWhileInteractive && isInteractive {
            present(HUDContent(title: nil, body: text, icon: .none), transient: true, duration: 5)
        } else {
            present(HUDContent(title: nil, body: text, icon: .none), transient: false, duration: 0)
        }
    }

    /// Show body text, then auto-clear after `duration` seconds.
    func flash(_ text: String, duration: TimeInterval = 4) {
        present(HUDContent(title: nil, body: text, icon: .none), transient: true, duration: duration)
    }

    /// Show a transient notification (icon + optional heading + body) that auto-clears.
    func showNotification(title: String?, body: String, icon: HUDIcon = .info, duration: TimeInterval = 5) {
        present(HUDContent(title: title, body: body, icon: icon), transient: true, duration: duration)
    }

    /// Show persistent navigation guidance (icon + body). Cleared explicitly via
    /// `clear()` when guidance stops.
    func showNavigation(_ text: String, icon: HUDIcon = .navigation) {
        // Plan KP: guidance and hazard lines are never paged and never wait behind an answer
        // card. An answer used to be a plain line the next guidance line replaced; a card gives
        // way the same way, rather than holding the line back for up to a minute.
        if showsAnswerCard { endInteractive() }
        // Plan KX §4: nor does the turn's Listening or Thinking card.
        if showsTurnState { endTurnState() }
        present(HUDContent(title: nil, body: text, icon: icon), transient: false, duration: 0)
    }

    /// Clear the HUD (keeps the transport alive for fast subsequent updates).
    func clear() {
        guard isEnabled else { return }
        // Plan KP: a producer clearing its own line (captions stopping, guidance ending) never
        // blanks an answer card held over it. The card ends by Close, a new answer, or its
        // lifetime.
        guard !showsAnswerCard else { return }
        // Plan KV: nor a page view, or its cue, held over it.
        guard heldPage == nil else { return }
        // Plan KX: nor the turn's card or an approval card, which end by their own rules.
        guard !showsTurnState, !showsApprovalCard else { return }
        guard isDisplayActive || lastRendered != nil || lastScreenKey != nil else { return }
        enqueue(.op(.clear))
    }

    /// Present an interactive screen (task card / menu). Drives the HUD into interactive
    /// mode; on-device selections route back via `onSelect(itemID)`. No-op when the
    /// feature is off or the glasses have no display.
    func present(screen: HUDScreen, onSelect: @escaping (String) -> Void) {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return }
        // Plan KX §2.2: a menu, task card or choice list is the wearer's doing; it reopens the lens.
        wearerLed()
        // Plan KX §3: under an approval card it goes underneath, and comes back when the approval
        // is answered — a task step that changed meanwhile never covers the question.
        if showsApprovalCard {
            underApproval = HeldUnderApproval(screen: screen, handler: onSelect, showsAnswerCard: false,
                                              showsTurnState: false, heldPage: nil, answerUnderPage: nil,
                                              pageTakesAnswerUnder: false)
            onDebugEvent?("HUD task card under the approval card: \(screen.title ?? "menu")")
            return
        }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = false
        showsTurnState = false
        flashingOverInteractive = false
        releasePageView()
        onDebugEvent?("HUD task card: \(screen.title ?? "menu")")
        enqueue(.screen(screen))
    }

    /// Plan KP P1: hold an answer card on the HUD — a new answer, or the card it already holds
    /// redrawn because more of the answer arrived. Not a press, so not gated: a new answer
    /// replaces whatever card was up. While a transient frame is over the card, only the held
    /// screen is updated and the flash's restore draws it.
    ///
    /// `wearerLed` (Plan KX §5): whether the wearer asked for this answer. A Direct-mode answer is
    /// always theirs; a live-mode answer is only when the wearer spoke (or pressed) that turn, so
    /// one the model volunteered (an announcement, the end of a tool call nobody is waiting on)
    /// stays off a lens they dismissed.
    @discardableResult
    func presentAnswerCard(_ screen: HUDScreen, wearerLed asked: Bool = true,
                           onSelect: @escaping (String) -> Void) -> Bool {
        guard acceptsAnswerCard else { return false }
        // Plan KX §2.2: a new answer is the wearer's (they asked); the card they dismissed growing
        // is not, and stays off the lens.
        if lensDismissed {
            if let dismissed = dismissedAnswerCard, screen.pageSet?.card == dismissed { return false }
            guard asked else { return false }
            wearerLed()
        }
        // Plan KV: under an open page view the answer waits, current, for the view to close.
        if heldPage == .view {
            answerUnderPage = (screen, onSelect)
            return true
        }
        heldPage = nil
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = true
        showsTurnState = false
        if !flashingOverInteractive { enqueue(.screen(screen)) }
        return true
    }

    /// Plan KP §2: whether a press issued against `revision` is still current. A stale one is
    /// logged (`hudPageTurnStale`) and must be dropped by the caller.
    func acceptsCardPress(issuedAgainst revision: UInt64) -> Bool {
        guard showsAnswerCard else { return false }
        return acceptsHeldScreenPress(issuedAgainst: revision)
    }

    /// Plan KP §2, for any held interactive screen (the band check's card, P3): whether a press
    /// issued against `revision` is still current. A stale one is logged (`hudPageTurnStale`) and
    /// must be dropped by the caller.
    func acceptsHeldScreenPress(issuedAgainst revision: UInt64) -> Bool {
        guard isInteractive else { return false }
        guard PageTurnGate.accept(turnRevision: revision, currentRevision: frameRevision) else {
            PrivacyLog.device(.hud, .hudPageTurnStale,
                              count: Int(clamping: frameRevision &- revision))
            onDebugEvent?("HUD page turn stale")
            return false
        }
        return true
    }

    /// Plan KP §2: a page turn (or the Actions screen and back), issued against `revision`.
    /// Drawn only when nothing has been enqueued since; otherwise dropped and logged, and the
    /// card is left as it was. Returns whether it was taken.
    @discardableResult
    func turnAnswerCard(to screen: HUDScreen, issuedAgainst revision: UInt64,
                        onSelect: @escaping (String) -> Void) -> Bool {
        guard acceptsCardPress(issuedAgainst: revision) else { return false }
        screenSelectionHandler = onSelect
        currentScreen = screen
        flashingOverInteractive = false
        enqueue(.screen(screen))
        return true
    }

    /// Leave interactive mode and clear the HUD so ambient producers resume.
    func endInteractive() {
        guard isInteractive else { return }
        // Plan KX §3: what ended is the screen under the approval card (a task finished, a menu
        // closed); the approval stays, and nothing comes back when it is answered.
        if showsApprovalCard {
            underApproval = nil
            return
        }
        isInteractive = false
        showsAnswerCard = false
        showsTurnState = false
        flashingOverInteractive = false
        releasePageView()
        currentScreen = nil
        screenSelectionHandler = nil
        onDebugEvent?("HUD interactive ended")
        enqueue(.op(.clear))
    }

    /// Fully tear down the display transport. Call on feature disable / mode switch /
    /// app teardown.
    func shutdown() async {
        pending = nil
        await activeBackend.shutdown()
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
    }

    // MARK: - Presentation

    private func present(_ content: HUDContent, transient: Bool, duration: TimeInterval) {
        // The web mirror (Plan BP) keeps the queue alive even without a native display —
        // that's the entitlement-free path; the backend send itself is capability-gated.
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return }
        // Plan KP §8 rule 3: while another app has the Display, no backlog. A notification or a
        // caption was spoken, or is live; it is dropped rather than queued for later.
        guard !holdsLens else { return }
        // While an interactive screen is held, suppress persistent ambient frames;
        // transient notifications still flash (and restore the screen on auto-clear).
        if isInteractive && !transient { return }
        var shaped = content
        shaped.body = HUDTextShaper.condense(content.body)
        shaped.title = content.title.map { HUDTextShaper.condense($0, max: HUDTextShaper.maxTitleLength) }
        let hasBody = !shaped.body.isEmpty
        let hasTitle = !(shaped.title?.isEmpty ?? true)
        guard hasBody || hasTitle else { return }

        let op = RenderOp.show(shaped)
        if transient && isInteractive { flashingOverInteractive = true }
        enqueue(.op(op))
        if transient {
            transientShowing = op
            scheduleAutoClear(for: op, after: duration)
        }
    }

    private func scheduleAutoClear(for op: RenderOp, after duration: TimeInterval) {
        autoClearGeneration += 1
        let generation = autoClearGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard let self, generation == self.autoClearGeneration else { return }
            let wasShowing = self.transientShowing == op
            if wasShowing { self.transientShowing = nil }
            // Only act if this frame is still what's on screen.
            guard self.lastRendered == op else {
                // Never drawn (a failed send), yet nothing replaced it: a page view held under it
                // still goes up, rather than waiting for a frame that never comes.
                if wasShowing, self.flashingOverInteractive, self.isInteractive, let screen = self.currentScreen {
                    self.flashingOverInteractive = false
                    self.enqueue(.screen(screen))
                }
                return
            }
            if self.isInteractive, let screen = self.currentScreen {
                self.flashingOverInteractive = false
                self.enqueue(.screen(screen))     // restore the held screen after the flash
            } else {
                self.enqueue(.op(.clear))         // auto-clear the just-shown transient frame
            }
        }
    }

    // MARK: - Render queue

    private func enqueue(_ frame: Frame) {
        // Plan KP §8: nothing is handed to the queue while another app has the Display, so the
        // session is never asked to start; `resumeLens()` draws the held state once it is ours.
        guard !holdsLens else {
            lensMissedFrames = true
            return
        }
        // Plan KX §2.2: the wearer dismissed the lens; only a wearer-led frame (which clears this
        // first) opens a session again. Nothing is held back for later either.
        guard !lensDismissed else { return }
        frameRevision &+= 1
        if case .screen = frame { heldScreenRevision = frameRevision }
        // Any frame after a transient one replaces it (its own auto-clear included).
        transientShowing = nil
        pending = frame
        guard !isRendering else { return }
        isRendering = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pending != nil {
                // Plan KX §2.4: space real sends. The wait happens before the frame is taken, so
                // anything enqueued meanwhile replaces it (latest wins) and only the newest goes.
                if self.testRenderSink == nil, self.deviceSupportsDisplay() {
                    let wait = self.sendPacer.delay(at: Date())
                    if wait > 0 { await self.paceSleep(wait) }
                }
                // Dismissed (or handed to another app) while waiting: nothing goes.
                guard !self.lensDismissed, !self.holdsLens, let frame = self.pending else {
                    self.pending = nil
                    break
                }
                self.pending = nil
                var sentKind: HUDSendRecord.Kind?
                let started = ContinuousClock.now
                do {
                    switch frame {
                    case .op(let op):
                        if op == self.lastRendered { continue } // skip redundant identical sends
                        self.updateMirror(for: op)
                        if let sink = self.testRenderSink {
                            sink(Self.descriptor(for: op))
                        } else if self.deviceSupportsDisplay() {
                            switch op {
                            case .show(let content):
                                sentKind = .text
                                try await self.activeBackend.showContent(
                                    title: content.title, body: content.body, icon: content.icon)
                                self.isDisplayActive = true
                                // Plan CU P1: marked here, where content reaches the backend, not
                                // where it was requested. The queue above is latest-wins, so a
                                // requested frame can be superseded and never render at all — a
                                // missing `hudRenderedAt` is that, not a missing mark call.
                                TurnRecorder.markHUDRendered(at: Date())
                            case .clear:
                                sentKind = .clear
                                try await self.activeBackend.clear()
                            }
                            self.recordSend(sentKind, started: started, outcome: .sent)
                        }
                        self.lastRendered = op
                        self.lastScreenKey = nil
                    case .screen(let screen):
                        if screen.renderKey == self.lastScreenKey {
                            // Plan KP: the page on the glasses is unchanged, but an answer card's
                            // readable pages may have grown behind it; the web mirror turns pages
                            // by itself, so it still gets them.
                            if screen.pageSet != nil { self.mirrorScreen = screen }
                            continue
                        }
                        self.mirrorScreen = screen
                        if let sink = self.testRenderSink {
                            sink(.screen(renderKey: screen.renderKey))
                        } else if self.deviceSupportsDisplay() {
                            let backend = self.activeBackend
                            let sent = Self.screen(screen, forBackendDrawingPictures: backend.drawsPictures)
                            sentKind = sent.picture != nil ? .picture : .screen
                            try await backend.send(screen: sent)
                            self.isDisplayActive = true
                            if sent.picture != nil {
                                self.onPictureSent?(backend.lastPictureBytes, Self.milliseconds(since: started))
                            }
                            self.recordSend(sentKind, started: started, outcome: .sent)
                        }
                        self.lastScreenKey = screen.renderKey
                        self.lastRendered = nil
                    }
                } catch {
                    let timedOut: Bool
                    if case GlassesDisplayError.sendTimedOut = error { timedOut = true } else { timedOut = false }
                    self.handleRenderError(error)
                    // Plan KX §2.4: a picture frame that failed goes once more as its text lines,
                    // unless something newer is already waiting or the failure was the lens being
                    // someone else's (a reading, not a failure).
                    if sentKind == .picture, case .screen(var screen) = frame, self.pending == nil,
                       Self.retriesWithoutPicture(after: error) {
                        self.recordSend(.picture, started: started, outcome: .retriedWithoutPicture)
                        screen.picture = nil
                        self.pending = .screen(screen)
                        continue
                    }
                    self.recordSend(sentKind, started: started, outcome: timedOut ? .timedOut : .failed)
                    break
                }
            }
            self.isRendering = false
        }
    }

    /// Plan KV §6: the screen as a backend gets it. One that does not draw pictures is never handed
    /// one: it gets the same screen without it, and renders the text lines as before.
    static func screen(_ screen: HUDScreen, forBackendDrawingPictures drawsPictures: Bool) -> HUDScreen {
        guard !drawsPictures, screen.picture != nil else { return screen }
        var stripped = screen
        stripped.picture = nil
        return stripped
    }

    private func updateMirror(for op: RenderOp) {
        switch op {
        case .show(let content):
            mirrorScreen = HUDScreen(title: content.title,
                                     lines: [HUDLine(content.body, icon: content.icon)])
        case .clear:
            mirrorScreen = nil
        }
    }

    private static func descriptor(for op: RenderOp) -> HUDFrame {
        switch op {
        case .show(let content): return .content(body: content.body, title: content.title, icon: content.icon)
        case .clear: return .clear
        }
    }

    // `previewFlexBox(for:)` — the on-phone FlexBox mirror — lives in
    // MetaDisplayBackend.swift (the SDK-importing file) as an extension of this class.

    /// Test helper: the `onClick` actions of the interactive buttons in `screen`'s
    /// rendered tree, in order, so a test can simulate Neural-Band selections without
    /// importing the SDK. Each fires exactly the routing the real button would.
    func testInteractiveButtonActions(for screen: HUDScreen) -> [() -> Void] {
        #if !AVENKIN_PHONE_ONLY
        return metaBackend.testButtonActions(for: screen)
        #else
        return screen.items.map { item in { [weak self] in self?.screenSelectionHandler?(item.id) } }
        #endif
    }

    private func handleRenderError(_ error: Error) {
        // Don't spam logs for the expected "no display" no-op path.
        if case GlassesDisplayError.noDisplay = error { return }
        // Plan KP §8: another app has the Display. A reading, not a failure: the backend keeps
        // (and follows) its session, nothing is torn down, and the lens is redrawn once it is ours.
        if case GlassesDisplayError.displayInUse = error {
            lastRendered = nil
            lastScreenKey = nil
            flashingOverInteractive = false
            lensMissedFrames = true
            return
        }
        PrivacyLog.device(.hud, .renderFailed, error: SafeErrorSummary(error))
        sendPacer.reset()
        // The on-screen diagnostics panel is a different sink with a different audience — the
        // wearer chose to open it — so it keeps the readable text the device log does not.
        onDebugEvent?("HUD error: \(String(describing: error))")
        // Drop references so the next render rebuilds the transport from scratch.
        activeBackend.resetAfterError()
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
        // A flash that failed to draw restores nothing; the held screen draws on its next change.
        flashingOverInteractive = false
    }
}

enum GlassesDisplayError: LocalizedError {
    case noDisplay
    case sessionUnavailable
    /// Plan KP §8: another app has the Display (our session is paused, or a start was refused).
    /// A reading, not a failure: nothing is torn down and nothing is retried until it is ours.
    case displayInUse
    /// Plan KX §2.4: a send did not come back within `HUDSendDeadline.seconds`.
    case sendTimedOut

    var errorDescription: String? {
        switch self {
        #if AVENKIN_PHONE_ONLY
        case .noDisplay: return "No display is available"
        #else
        case .noDisplay: return "Connected glasses have no in-lens display"
        #endif
        case .sessionUnavailable: return "Display session unavailable"
        case .displayInUse: return "Another app is using the display"
        case .sendTimedOut: return "The display did not answer in time"
        }
    }
}
