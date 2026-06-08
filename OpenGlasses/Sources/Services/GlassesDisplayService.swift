import Foundation
import MWDATCore
import MWDATDisplay

/// Mirrors short text to the Ray-Ban *Display* in-lens HUD (DAT SDK `MWDATDisplay`).
///
/// Phase 1: surfaces AI responses and the live ambient-caption line. Everything is
/// additive — the on-phone overlay and TTS are untouched. On glasses without a
/// display (`Device.supportsDisplay() == false`) every call is a safe no-op and no
/// `DeviceSession` is ever created, so non-Display Ray-Ban hardware is unaffected.
///
/// Session ownership: this service manages its own `DeviceSession` (via
/// `AutoDeviceSelector`), separate from `CameraService`. The SDK allows a single
/// session per device, so while the HUD session is held the camera falls back to its
/// existing iPhone-camera path. Unifying the two into one shared `DeviceSession`
/// (camera + display capabilities on one session) is a tracked follow-up; it is out of
/// scope for Phase 1 and only affects Display-model hardware with the flag on.
@MainActor
final class GlassesDisplayService: ObservableObject {
    /// True once the display capability is started and content is being shown.
    @Published private(set) var isDisplayActive = false
    /// Whether the currently-active glasses report an in-lens display.
    @Published private(set) var hasDisplayCapability = false

    /// Debug event callback (wired to `AppState.addDebugEvent`).
    var onDebugEvent: ((String) -> Void)?

    /// Lazily initialized after `Wearables.configure()` has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    private var display: Display?

    /// Latest-wins render queue. Rapid caption updates collapse to the most recent
    /// frame so we never flood the BLE link — only one `send` is ever in flight.
    private var pendingText: String?
    private var isRendering = false
    /// Last text actually pushed to the HUD; identical updates are skipped.
    private var lastSentText: String?

    /// Max characters to show on the HUD — kept short for legibility in-lens.
    private static let maxLength = 120

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

    /// Show a concise line of text on the HUD. No-op when the feature is off or the
    /// glasses have no display. Text is trimmed and truncated for legibility.
    func showText(_ text: String) {
        guard isEnabled, deviceSupportsDisplay() else { return }
        let trimmed = Self.condense(text)
        guard !trimmed.isEmpty else { return }
        scheduleRender(trimmed)
    }

    /// Briefly show text, then clear it after `duration` seconds (if nothing newer
    /// has been shown in the meantime).
    func flash(_ text: String, duration: TimeInterval = 4.0) {
        guard isEnabled, deviceSupportsDisplay() else { return }
        let trimmed = Self.condense(text)
        guard !trimmed.isEmpty else { return }
        scheduleRender(trimmed)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            // Only clear if this flash is still the thing on screen.
            if self.lastSentText == trimmed { self.clear() }
        }
    }

    /// Clear the HUD (keeps the session alive for fast subsequent updates).
    func clear() {
        guard isEnabled else { return }
        guard isDisplayActive || display != nil else { return }
        scheduleRender("")
    }

    /// Fully tear down the display session. Call on feature disable / mode switch /
    /// app teardown.
    func shutdown() async {
        pendingText = nil
        await teardownDisplay()
    }

    // MARK: - Render queue

    private func scheduleRender(_ text: String) {
        pendingText = text
        guard !isRendering else { return }
        isRendering = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.pendingText {
                self.pendingText = nil
                do {
                    if next.isEmpty {
                        try await self.renderClear()
                    } else {
                        try await self.renderText(next)
                    }
                    self.lastSentText = next.isEmpty ? nil : next
                } catch {
                    self.handleRenderError(error)
                    break
                }
            }
            self.isRendering = false
        }
    }

    private func renderText(_ text: String) async throws {
        let display = try await ensureDisplay()
        let view = FlexBox(
            direction: .column,
            spacing: 4,
            alignment: .start,
            padding: EdgeInsets(all: 12)
        ) {
            Text(text, style: .body, color: .primary)
        }
        try await display.send(view)
    }

    private func renderClear() async throws {
        // Nothing to clear if we never started a session.
        guard let display else { return }
        let empty = FlexBox(direction: .column) {}
        try await display.send(empty)
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
        lastSentText = nil
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
    }

    // MARK: - Text shaping

    /// Collapse whitespace and truncate to a HUD-legible length.
    private static func condense(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let cut = collapsed.prefix(maxLength)
        // Prefer to break on the last space so we don't slice a word in half.
        if let lastSpace = cut.lastIndex(of: " "), lastSpace > cut.index(cut.startIndex, offsetBy: maxLength / 2) {
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
