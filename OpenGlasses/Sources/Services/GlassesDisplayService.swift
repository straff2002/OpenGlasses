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

    /// Whether an answer may be shown as a card right now: the HUD is on, something can show it
    /// (a display or the mirror), and nothing but an answer card is held.
    var acceptsAnswerCard: Bool {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return false }
        return !isInteractive || showsAnswerCard
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

    /// The glasses' link and worn state, from `GlassesConnectionService` (`isConnected`, which is
    /// `linkState == .connected`, and `isWorn`).
    func updateGlassesLink(connected: Bool, worn: Bool?) {
        guard connected != glassesConnected || worn != glassesWorn else { return }
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

    /// The support report's lines about the reading.
    var availabilityReportLines: [String] {
        ["Display reading now: \(displayAvailability.reportName) (\(sessionReading.reportName))"]
            + availabilityLog.reportLines()
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
        present(HUDContent(title: nil, body: text, icon: icon), transient: false, duration: 0)
    }

    /// Clear the HUD (keeps the transport alive for fast subsequent updates).
    func clear() {
        guard isEnabled else { return }
        // Plan KP: a producer clearing its own line (captions stopping, guidance ending) never
        // blanks an answer card held over it. The card ends by Close, a new answer, or its
        // lifetime.
        guard !showsAnswerCard else { return }
        guard isDisplayActive || lastRendered != nil || lastScreenKey != nil else { return }
        enqueue(.op(.clear))
    }

    /// Present an interactive screen (task card / menu). Drives the HUD into interactive
    /// mode; on-device selections route back via `onSelect(itemID)`. No-op when the
    /// feature is off or the glasses have no display.
    func present(screen: HUDScreen, onSelect: @escaping (String) -> Void) {
        guard isEnabled, deviceSupportsDisplay() || Config.hudMirrorEnabled else { return }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = false
        flashingOverInteractive = false
        onDebugEvent?("HUD task card: \(screen.title ?? "menu")")
        enqueue(.screen(screen))
    }

    /// Plan KP P1: hold an answer card on the HUD — a new answer, or the card it already holds
    /// redrawn because more of the answer arrived. Not a press, so not gated: a new answer
    /// replaces whatever card was up. While a transient frame is over the card, only the held
    /// screen is updated and the flash's restore draws it.
    @discardableResult
    func presentAnswerCard(_ screen: HUDScreen, onSelect: @escaping (String) -> Void) -> Bool {
        guard acceptsAnswerCard else { return false }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        showsAnswerCard = true
        if !flashingOverInteractive { enqueue(.screen(screen)) }
        return true
    }

    /// Plan KP §2: whether a press issued against `revision` is still current. A stale one is
    /// logged (`hudPageTurnStale`) and must be dropped by the caller.
    func acceptsCardPress(issuedAgainst revision: UInt64) -> Bool {
        guard showsAnswerCard else { return false }
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
        isInteractive = false
        showsAnswerCard = false
        flashingOverInteractive = false
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
        if transient { scheduleAutoClear(for: op, after: duration) }
    }

    private func scheduleAutoClear(for op: RenderOp, after duration: TimeInterval) {
        autoClearGeneration += 1
        let generation = autoClearGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard let self, generation == self.autoClearGeneration else { return }
            // Only act if this frame is still what's on screen.
            guard self.lastRendered == op else { return }
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
        frameRevision &+= 1
        if case .screen = frame { heldScreenRevision = frameRevision }
        pending = frame
        guard !isRendering else { return }
        isRendering = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let frame = self.pending {
                self.pending = nil
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
                                try await self.activeBackend.showContent(
                                    title: content.title, body: content.body, icon: content.icon)
                                self.isDisplayActive = true
                                // Plan CU P1: marked here, where content reaches the backend, not
                                // where it was requested. The queue above is latest-wins, so a
                                // requested frame can be superseded and never render at all — a
                                // missing `hudRenderedAt` is that, not a missing mark call.
                                TurnRecorder.markHUDRendered(at: Date())
                            case .clear:
                                try await self.activeBackend.clear()
                            }
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
                            try await self.activeBackend.send(screen: screen)
                            self.isDisplayActive = true
                        }
                        self.lastScreenKey = screen.renderKey
                        self.lastRendered = nil
                    }
                } catch {
                    self.handleRenderError(error)
                    break
                }
            }
            self.isRendering = false
        }
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

    var errorDescription: String? {
        switch self {
        #if AVENKIN_PHONE_ONLY
        case .noDisplay: return "No display is available"
        #else
        case .noDisplay: return "Connected glasses have no in-lens display"
        #endif
        case .sessionUnavailable: return "Display session unavailable"
        case .displayInUse: return "Another app is using the display"
        }
    }
}
