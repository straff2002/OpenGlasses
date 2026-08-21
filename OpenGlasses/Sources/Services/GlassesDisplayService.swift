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

    private func wire(_ backend: GlassesDisplayBackend) {
        backend.onItemSelected = { [weak self] id in
            self?.screenSelectionHandler?(id)
        }
        backend.onTransportError = { [weak self] error in
            self?.handleRenderError(error)
        }
        if let meta = backend as? MetaDisplayBackend {
            meta.onDebugEvent = { [weak self] message in self?.onDebugEvent?(message) }
        }
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
        let supported = testCapabilityOverride ?? activeBackend.isAvailable
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
        present(HUDContent(title: nil, body: text, icon: icon), transient: false, duration: 0)
    }

    /// Clear the HUD (keeps the transport alive for fast subsequent updates).
    func clear() {
        guard isEnabled else { return }
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
        onDebugEvent?("HUD task card: \(screen.title ?? "menu")")
        enqueue(.screen(screen))
    }

    /// Leave interactive mode and clear the HUD so ambient producers resume.
    func endInteractive() {
        guard isInteractive else { return }
        isInteractive = false
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
                self.enqueue(.screen(screen))     // restore the held screen after the flash
            } else {
                self.enqueue(.op(.clear))         // auto-clear the just-shown transient frame
            }
        }
    }

    // MARK: - Render queue

    private func enqueue(_ frame: Frame) {
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
                        if screen.renderKey == self.lastScreenKey { continue }
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
        metaBackend.testButtonActions(for: screen)
    }

    private func handleRenderError(_ error: Error) {
        // Don't spam logs for the expected "no display" no-op path.
        if case GlassesDisplayError.noDisplay = error { return }
        NSLog("[Display] HUD render failed: %@", String(describing: error))
        onDebugEvent?("HUD error: \(String(describing: error))")
        // Drop references so the next render rebuilds the transport from scratch.
        activeBackend.resetAfterError()
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
    }
}

enum GlassesDisplayError: LocalizedError {
    case noDisplay
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Connected glasses have no in-lens display"
        case .sessionUnavailable: return "Display session unavailable"
        }
    }
}
