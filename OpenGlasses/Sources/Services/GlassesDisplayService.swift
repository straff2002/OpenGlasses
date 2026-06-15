import Foundation
import MWDATCore
import MWDATDisplay

/// Mirrors short content to the Ray-Ban *Display* in-lens HUD (DAT SDK `MWDATDisplay`).
///
/// Producers wired so far:
/// - Phase 1: AI responses (`TextToSpeechService`) and the live ambient-caption line.
/// - Phase 2: notifications (proactive/calendar + geofence alerts) and Navigation
///   Assist guidance, rendered with an icon + heading + body.
///
/// Everything is additive — the on-phone overlay and TTS are untouched. On glasses
/// without a display (`Device.supportsDisplay() == false`) every call is a safe no-op
/// and no `DeviceSession` is ever created, so non-Display Ray-Ban hardware is unaffected.
///
/// Session ownership: this service manages its own `DeviceSession` (via
/// `AutoDeviceSelector`), separate from `CameraService`. The SDK allows a single
/// session per device, so while the HUD session is held the camera falls back to its
/// existing iPhone-camera path. Unifying the two into one shared `DeviceSession`
/// (camera + display capabilities on one session) is a tracked follow-up.
@MainActor
final class GlassesDisplayService: ObservableObject {
    /// True once the display capability is started and content is being shown.
    @Published private(set) var isDisplayActive = false
    /// Whether the currently-active glasses report an in-lens display.
    @Published private(set) var hasDisplayCapability = false

    /// Debug event callback (wired to `AppState.addDebugEvent`).
    var onDebugEvent: ((String) -> Void)?

    /// Semantic icon for HUD content. Mapped internally to a `MWDATDisplay.IconName`
    /// so producers don't need to import the SDK.
    enum HUDIcon: Equatable {
        case none
        case info, success, warning, error
        case navigation, hazard
        case calendar, location, reminder, message

        fileprivate var iconName: IconName? {
            switch self {
            case .none: return nil
            case .info: return .iCircle
            case .success: return .checkmarkCircle
            case .warning: return .exclamationTriangle
            case .error: return .exclamationCircle
            case .navigation: return .compassNorthUpRed
            case .hazard: return .exclamationTriangle
            case .calendar: return .calendar
            case .location: return .house
            case .reminder: return .bell
            case .message: return .speechBubble
            }
        }
    }

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

    /// Lazily initialized after `Wearables.configure()` has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    private var display: Display?

    /// Latest-wins render queue. Rapid updates collapse to the most recent frame so we
    /// never flood the BLE link — only one `send` is ever in flight.
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
    private var currentScreen: HUDScreen?
    private var screenSelectionHandler: ((String) -> Void)?

    /// Max characters for the body line — kept short for in-lens legibility.
    private static let maxLength = 120
    /// Max characters for a heading.
    private static let maxTitleLength = 40

    // MARK: - Capability

    /// Whether the active glasses expose an in-lens display. Cheap, synchronous, and
    /// safe to call frequently. Updates `hasDisplayCapability` as a side effect.
    @discardableResult
    func deviceSupportsDisplay() -> Bool {
        let supported: Bool = {
            guard let id = deviceSelector.activeDevice,
                  let device = Wearables.shared.deviceForIdentifier(id) else {
                return false
            }
            return device.supportsDisplay()
        }()
        if hasDisplayCapability != supported { hasDisplayCapability = supported }
        return supported
    }

    private var isEnabled: Bool { Config.glassesDisplayEnabled }

    // MARK: - Public API

    /// Show a concise line of body text. No-op when the feature is off or the glasses
    /// have no display. Used by the Phase 1 producers (AI replies, ambient captions).
    func showText(_ text: String) {
        present(HUDContent(title: nil, body: text, icon: .none), transient: false, duration: 0)
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

    /// Clear the HUD (keeps the session alive for fast subsequent updates).
    func clear() {
        guard isEnabled else { return }
        guard isDisplayActive || display != nil else { return }
        enqueue(.op(.clear))
    }

    /// Present an interactive screen (task card / menu). Drives the HUD into interactive
    /// mode; band selections route back via `onSelect(itemID)`. No-op when the feature is
    /// off or the glasses have no display.
    func present(screen: HUDScreen, onSelect: @escaping (String) -> Void) {
        guard isEnabled, deviceSupportsDisplay() else { return }
        screenSelectionHandler = onSelect
        currentScreen = screen
        isInteractive = true
        enqueue(.screen(screen))
    }

    /// Leave interactive mode and clear the HUD so ambient producers resume.
    func endInteractive() {
        isInteractive = false
        currentScreen = nil
        screenSelectionHandler = nil
        enqueue(.op(.clear))
    }

    /// Fully tear down the display session. Call on feature disable / mode switch /
    /// app teardown.
    func shutdown() async {
        pending = nil
        await teardownDisplay()
    }

    // MARK: - Presentation

    private func present(_ content: HUDContent, transient: Bool, duration: TimeInterval) {
        guard isEnabled, deviceSupportsDisplay() else { return }
        // While an interactive screen is held, suppress persistent ambient frames;
        // transient notifications still flash (and restore the screen on auto-clear).
        if isInteractive && !transient { return }
        var shaped = content
        shaped.body = Self.condense(content.body)
        shaped.title = content.title.map { Self.condense($0, max: Self.maxTitleLength) }
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
                self.enqueue(.screen(screen))   // restore the held screen after the flash
            } else {
                self.clear()
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
                        switch op {
                        case .show(let content): try await self.renderContent(content)
                        case .clear: try await self.renderClear()
                        }
                        self.lastRendered = op
                        self.lastScreenKey = nil
                    case .screen(let screen):
                        if screen.renderKey == self.lastScreenKey { continue }
                        try await self.renderScreen(screen)
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

    private func renderContent(_ content: HUDContent) async throws {
        let display = try await ensureDisplay()
        let iconName = content.icon.iconName
        let hasTitle = !(content.title?.isEmpty ?? true)

        let view = FlexBox(
            direction: .column,
            spacing: 6,
            alignment: .start,
            padding: EdgeInsets(all: 12)
        ) {
            if hasTitle, let title = content.title {
                // Heading row (icon + title), then body underneath.
                if let iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(title, style: .heading, color: .primary)
                    }
                } else {
                    Text(title, style: .heading, color: .primary)
                }
                Text(content.body, style: .body, color: .secondary)
            } else {
                // Body only — inline with the icon when present.
                if let iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(content.body, style: .body, color: .primary)
                    }
                } else {
                    Text(content.body, style: .body, color: .primary)
                }
            }
        }
        try await display.send(view)
    }

    private func renderClear() async throws {
        // Nothing to clear if we never started a session.
        guard let display else { return }
        let empty = FlexBox(direction: .column) {}
        try await display.send(empty)
    }

    private func renderScreen(_ screen: HUDScreen) async throws {
        let display = try await ensureDisplay()
        let view = FlexBox(
            direction: .column,
            spacing: 6,
            alignment: .start,
            padding: EdgeInsets(all: 12)
        ) {
            if let title = screen.title, !title.isEmpty {
                Text(Self.condense(title, max: Self.maxTitleLength), style: .heading, color: .primary)
            }
            for line in screen.lines {
                let text = Self.condense(line.text)
                if let iconName = line.icon.iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(text, style: line.emphasis.textStyle, color: line.emphasis.textColor)
                    }
                } else {
                    Text(text, style: line.emphasis.textStyle, color: line.emphasis.textColor)
                }
            }
            for item in screen.items {
                // Capture only Sendable values (id + presentation) — never the HUDItem,
                // whose `action` closure isn't Sendable. Selection routes back by id.
                let id = item.id
                let label = Self.condense(item.label, max: Self.maxTitleLength)
                let style = item.style.buttonStyle
                let iconName = item.icon.iconName
                Button(label: label, style: style, iconName: iconName, onClick: { [weak self] in
                    Task { @MainActor in self?.screenSelectionHandler?(id) }
                })
            }
        }
        try await display.send(view)
    }

    // MARK: - Session lifecycle

    private func ensureDisplay() async throws -> Display {
        // Reuse a live display/session.
        if let display, deviceSession?.state == .started {
            return display
        }
        // Drop stale references if the session died underneath us.
        if deviceSession?.state == .stopped || deviceSession?.state == .idle {
            display = nil
            deviceSession = nil
            isDisplayActive = false
        }

        guard deviceSupportsDisplay() else { throw GlassesDisplayError.noDisplay }

        let session: DeviceSession
        if let existing = deviceSession {
            session = existing
        } else {
            session = try Wearables.shared.createSession(deviceSelector: deviceSelector)
            deviceSession = session
        }

        if session.state != .started {
            try session.start()
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if session.state == .started || session.state == .stopped { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard session.state == .started else { throw GlassesDisplayError.sessionUnavailable }

        let display: Display
        if let existing = self.display {
            display = existing
        } else {
            // We exclusively own this session, so the display capability can't already
            // be active. `addDisplay()` throws DeviceSessionError; surface failures via
            // the render-error path (which tears down and rebuilds a fresh session).
            display = try session.addDisplay()
            self.display = display
        }

        await display.start()
        isDisplayActive = true
        onDebugEvent?("HUD display started")
        return display
    }

    private func teardownDisplay() async {
        if let display {
            await display.stop()
        }
        display = nil
        deviceSession?.stop()
        deviceSession = nil
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
    }

    private func handleRenderError(_ error: Error) {
        // Don't spam logs for the expected "no display" no-op path.
        if case GlassesDisplayError.noDisplay = error { return }
        NSLog("[Display] HUD render failed: %@", String(describing: error))
        onDebugEvent?("HUD error: \(String(describing: error))")
        // Drop references so the next render rebuilds the session from scratch.
        display = nil
        deviceSession?.stop()
        deviceSession = nil
        isDisplayActive = false
        lastRendered = nil
        lastScreenKey = nil
    }

    // MARK: - Text shaping

    /// Collapse whitespace and truncate to a HUD-legible length.
    private static func condense(_ text: String, max: Int = maxLength) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        let cut = collapsed.prefix(max)
        // Prefer to break on the last space so we don't slice a word in half.
        if let lastSpace = cut.lastIndex(of: " "), lastSpace > cut.index(cut.startIndex, offsetBy: max / 2) {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
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

// MARK: - HUD model → SDK mapping (Plan X)

fileprivate extension HUDEmphasis {
    var textStyle: TextStyle {
        switch self {
        case .primary, .secondary: return .body
        case .meta: return .meta
        }
    }
    var textColor: TextColor {
        switch self {
        case .primary: return .primary
        case .secondary, .meta: return .secondary
        }
    }
}

fileprivate extension HUDButtonStyle {
    var buttonStyle: ButtonStyle {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .outline: return .outline
        }
    }
}
