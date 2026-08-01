import Foundation
import MWDATCore
import MWDATDisplay

/// Plan AH — the widened display-backend seam. `GlassesDisplayService` keeps everything
/// backend-neutral (render queue, dedup, interactive gate, flash-then-restore, condensing);
/// a backend owns capability, transport lifecycle, the `HUDScreen`/content → device mapping,
/// and the input channel back (band tap on Meta, temple gesture on EVEN).
@MainActor
protocol GlassesDisplayBackend: AnyObject {
    /// Capability gate — replaces the service's direct `deviceSupportsDisplay()` check.
    var isAvailable: Bool { get }

    /// Content-level ambient frame (title + body + icon — `showText` alone would drop the
    /// notification/navigation shape on a non-FlexBox backend).
    func showContent(title: String?, body: String, icon: HUDIcon) async throws
    func send(screen: HUDScreen) async throws
    func clear() async throws

    /// Full transport teardown (feature off / mode switch / app teardown).
    func shutdown() async
    /// Drop failed transport state so the next render rebuilds from scratch.
    func resetAfterError()

    /// Input events back to the service: an interactive item was selected on-device.
    var onItemSelected: ((String) -> Void)? { get set }
    /// Asynchronous transport failure (a BLE link dropping mid-session) — render-path
    /// errors throw instead. The service resets its dedup state so the next render
    /// rebuilds the transport.
    var onTransportError: ((Error) -> Void)? { get set }
}

/// The Ray-Ban Display path (DAT `MWDATDisplay`) behind the seam — a pure extraction of what
/// `GlassesDisplayService` did directly; no behavior change, existing HUD tests stay green
/// (they capture above the backend via `testRenderSink`).
///
/// Session ownership: this backend manages its own `DeviceSession` (via `AutoDeviceSelector`),
/// separate from `CameraService`. The SDK allows a single session per device, so while the HUD
/// session is held the camera falls back to its existing iPhone-camera path.
@MainActor
final class MetaDisplayBackend: GlassesDisplayBackend {

    var onItemSelected: ((String) -> Void)?
    /// Meta render failures throw from the render calls; nothing fires this.
    var onTransportError: ((Error) -> Void)?
    var onDebugEvent: ((String) -> Void)?
    /// True once the display capability is started and content is being shown.
    private(set) var isDisplayActive = false

    /// Lazily initialized after `Wearables.configure()` has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    private var display: Display?

    // MARK: - GlassesDisplayBackend

    var isAvailable: Bool {
        // Single choke point for the HUD: renders gate on this, so an unconfigured SDK
        // reports "no display" instead of trapping on `deviceSelector`/`Wearables.shared`.
        guard WearablesBootstrap.ensureConfigured() else { return false }
        guard let id = deviceSelector.activeDevice,
              let device = Wearables.shared.deviceForIdentifier(id) else {
            return false
        }
        return device.supportsDisplay()
    }

    func showContent(title: String?, body: String, icon: HUDIcon) async throws {
        let display = try await ensureDisplay()
        let iconName = icon.metaIconName
        let hasTitle = !(title?.isEmpty ?? true)

        let view = FlexBox(
            direction: .column,
            spacing: 6,
            alignment: .start,
            padding: EdgeInsets(all: 12)
        ) {
            if hasTitle, let title {
                // Heading row (icon + title), then body underneath.
                if let iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(title, style: .heading, color: .primary)
                    }
                } else {
                    Text(title, style: .heading, color: .primary)
                }
                Text(body, style: .body, color: .secondary)
            } else {
                // Body only — inline with the icon when present.
                if let iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(body, style: .body, color: .primary)
                    }
                } else {
                    Text(body, style: .body, color: .primary)
                }
            }
        }
        try await display.send(view)
    }

    func send(screen: HUDScreen) async throws {
        let display = try await ensureDisplay()
        try await display.send(makeScreenView(screen))
    }

    func clear() async throws {
        // Nothing to clear if we never started a session.
        guard let display else { return }
        // DAT 0.8.0: explicit clear instead of sending an empty FlexBox.
        try await display.clearDisplay()
    }

    func shutdown() async {
        if let display {
            // Blank the waveguide BEFORE stopping, and give the clear a beat to land —
            // stopping with content still up can surface the system home screen on the
            // lens instead of going dark (device-traced ordering; iOS DAT has no
            // `removeDisplay`, so clear → settle → stop is the whole discipline).
            try? await display.clearDisplay()
            try? await Task.sleep(nanoseconds: 200_000_000)
            display.stop()  // DAT 0.8.0: Display.stop() is synchronous
        }
        display = nil
        deviceSession?.stop()
        deviceSession = nil
        isDisplayActive = false
    }

    func resetAfterError() {
        display = nil
        deviceSession?.stop()
        deviceSession = nil
        isDisplayActive = false
    }

    // MARK: - Screen tree

    /// Build the interactive `FlexBox` for `screen`. Internal and free of SDK session
    /// state so tests can inspect the component tree and invoke each Button's `onClick`
    /// to simulate a Neural-Band selection.
    func makeScreenView(_ screen: HUDScreen) -> FlexBox {
        // Pre-shape all text and presentation here (MainActor context) so the
        // result-builder closure below never references anything actor-isolated.
        // Each button model carries only Sendable values — never the HUDItem, whose
        // `action` closure isn't Sendable; selection routes back by id.
        let headingText = screen.title.flatMap { $0.isEmpty ? nil : HUDTextShaper.condense($0, max: HUDTextShaper.maxTitleLength) }
        let lineModels = screen.lines.map { line in
            (text: HUDTextShaper.condense(line.text), iconName: line.icon.metaIconName,
             style: line.emphasis.textStyle, color: line.emphasis.textColor)
        }
        let buttonModels = screen.items.map { item in
            (id: item.id, label: HUDTextShaper.condense(item.label, max: HUDTextShaper.maxTitleLength),
             style: item.style.buttonStyle, iconName: item.icon.metaIconName)
        }

        return FlexBox(
            direction: .column,
            spacing: 6,
            alignment: .start,
            padding: EdgeInsets(all: 12)
        ) {
            if let headingText {
                Text(headingText, style: .heading, color: .primary)
            }
            for line in lineModels {
                if let iconName = line.iconName {
                    FlexBox(direction: .row, spacing: 6, alignment: .center) {
                        Icon(name: iconName)
                        Text(line.text, style: line.style, color: line.color)
                    }
                } else {
                    Text(line.text, style: line.style, color: line.color)
                }
            }
            for button in buttonModels {
                let id = button.id
                Button(label: button.label, style: button.style, iconName: button.iconName, onClick: { [weak self] in
                    Task { @MainActor in self?.onItemSelected?(id) }
                })
            }
        }
    }

    /// Test helper: the `onClick` actions of the interactive buttons in `screen`'s
    /// rendered tree, in order (simulated Neural-Band selections).
    func testButtonActions(for screen: HUDScreen) -> [() -> Void] {
        makeScreenView(screen).children
            .compactMap { ($0 as? Button)?.onClick }
            .map { onClick in { onClick() } }
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

        guard isAvailable else { throw GlassesDisplayError.noDisplay }

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

        display.start()  // DAT 0.8.0: Display.start() is synchronous
        isDisplayActive = true
        onDebugEvent?("HUD display started")
        return display
    }
}

// MARK: - Phone mirror

extension GlassesDisplayService {
    /// Build the SDK view tree for `screen` for the on-phone preview/mirror
    /// (`HUDPreviewView`). Session-free; the returned tree's button taps route nowhere.
    /// Shares `makeScreenView` with the on-glasses path so the phone mirror is a single
    /// source of truth. Lives here so the service file stays SDK-free (Plan AH).
    static func previewFlexBox(for screen: HUDScreen) -> FlexBox {
        MetaDisplayBackend().makeScreenView(screen)
    }
}

// MARK: - HUD model → SDK mapping (Plan X)

extension HUDIcon {
    /// The DAT icon for this semantic icon; Meta-backend-private in spirit, internal so
    /// the on-phone FlexBox mirror can share the mapping.
    var metaIconName: IconName? {
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
