import Foundation
#if !AVENKIN_PHONE_ONLY
import MWDATCore
#endif
#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
#endif
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

#if !AVENKIN_PHONE_ONLY
/// Plan KP P1b: the part of a DAT `DeviceSession` the display backend drives, so the in-use rule
/// (§8 rule 2: a paused session is never started again by us, nor torn down) is testable headless.
/// `DATDisplaySession` is the one real implementation; tests hand the backend a fake through
/// `MetaDisplayBackend.testMakeSession` and never touch `Wearables.shared`.
@MainActor
protocol DisplaySessionControl: AnyObject {
    var sessionState: DisplaySessionState { get }
    func start() throws
    func stop()
    /// The session's states as they change. Finishes once the session reaches `.stopped`
    /// (`DeviceSession.stateStream()`'s contract since DAT 0.9.0).
    func stateUpdates() -> AsyncStream<DisplaySessionState>
    func addDisplay() throws -> Display
}

/// A real `DeviceSession` behind `DisplaySessionControl`.
@MainActor
final class DATDisplaySession: DisplaySessionControl {
    private let session: DeviceSession

    init(_ session: DeviceSession) {
        self.session = session
    }

    var sessionState: DisplaySessionState { DisplaySessionState(session.state) }
    func start() throws { try session.start() }   // synchronous; the state follows
    func stop() { session.stop() }
    func addDisplay() throws -> Display { try session.addDisplay() }

    func stateUpdates() -> AsyncStream<DisplaySessionState> {
        let states = session.stateStream()
        return AsyncStream { continuation in
            let relay = Task {
                for await state in states { continuation.yield(DisplaySessionState(state)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

extension DisplaySessionState {
    init(_ state: DeviceSessionState) {
        switch state {   // `DeviceSessionState` is @frozen
        case .idle: self = .idle
        case .starting: self = .starting
        case .started: self = .started
        case .paused: self = .paused
        case .stopping: self = .stopping
        case .stopped: self = .stopped
        }
    }
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
    private var session: DisplaySessionControl?
    private var display: Display?
    /// Follows the session's own states (`stateStream()`) for as long as we hold it.
    private var sessionWatch: Task<Void, Never>?
    /// Bumped whenever a refusal is set or cleared, so an older expiry never clears a newer one.
    private var refusalGeneration = 0

    // MARK: - When the Display is in use (Plan KP P1b)

    /// What the session last said, for `DisplayAvailability`. Set on every state the session
    /// reports and on a refused start; `onSessionReading` hears each change.
    private(set) var sessionReading = DisplaySessionReading() {
        didSet { if sessionReading != oldValue { onSessionReading?(sessionReading) } }
    }
    var onSessionReading: ((DisplaySessionReading) -> Void)?

    /// A refused start reads as `.inUse` for this long, then the next frame may try once more. A
    /// refusal is not an interruption: the session never had the Display, so trying again later
    /// takes nothing back. Without the expiry a refusal would hold the HUD dark until relaunch,
    /// because nothing renders while the reading is `.inUse`.
    static let startRefusalExpiry: TimeInterval = 30

    /// Test seams. `testIsAvailable` stands in for the SDK's device lookup and `testMakeSession`
    /// for `Wearables.shared.createSession`, so a test drives the session rule with a fake.
    /// `scheduleRefusalExpiry` runs `fire` after `delay` (production sleeps on the main actor).
    var testIsAvailable: Bool?
    var testMakeSession: (() throws -> DisplaySessionControl)?
    var scheduleRefusalExpiry: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    // MARK: - GlassesDisplayBackend

    var isAvailable: Bool {
        if let testIsAvailable { return testIsAvailable }
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
            // Plan KP §8: not while another app has the Display: the lens is theirs to blank.
            if session?.sessionState != .paused {
                try? await display.clearDisplay()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            display.stop()  // DAT 0.8.0: Display.stop() is synchronous
        }
        // The wearer turned the HUD off (or the app is going): a full teardown, paused or not.
        dropSession()
        clearStartRefusal()
    }

    func resetAfterError() {
        // Plan KP §8 rule 2: a session another app has interrupted is never torn down by a render
        // error. It is followed back to `started` instead.
        guard session?.sessionState != .paused else { return }
        dropSession()
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
            // DAT 0.9.0 `ButtonGroup`: the sanctioned container for button rows (bare
            // buttons as loose FlexBox children predate it; flex params on a Button wrap
            // it in a label-clipping FlexChildWrapper, which the group avoids).
            if !buttonModels.isEmpty {
                ButtonGroup(alignment: .center) {
                    for button in buttonModels {
                        let id = button.id
                        Button(label: button.label, style: button.style, iconName: button.iconName, onClick: { [weak self] in
                            Task { @MainActor in self?.onItemSelected?(id) }
                        })
                    }
                }
            }
        }
    }

    /// Test helper: the `onClick` actions of the interactive buttons in `screen`'s
    /// rendered tree, in order (simulated Neural-Band selections). Buttons live inside
    /// the tree's `ButtonGroup` (with a loose-Button fallback for future shapes).
    func testButtonActions(for screen: HUDScreen) -> [() -> Void] {
        makeScreenView(screen).children
            .flatMap { child -> [Button] in
                if let group = child as? ButtonGroup { return group.buttons }
                if let button = child as? Button { return [button] }
                return []
            }
            .compactMap(\.onClick)
            .map { onClick in { onClick() } }
    }

    // MARK: - Session lifecycle

    private func ensureDisplay() async throws -> Display {
        let session = try await prepareSession()
        if let display {
            // Reuse the live display. After a pause the capability may have stopped with the
            // session; start it again only then (`Display.start()` is synchronous).
            if display.state == .stopped { display.start() }
            return display
        }
        // We exclusively own this session, so the display capability can't already be active.
        // `addDisplay()` throws DeviceSessionError; surface failures via the render-error path
        // (which tears down and rebuilds a fresh session).
        let display = try session.addDisplay()
        self.display = display
        display.start()  // DAT 0.8.0: Display.start() is synchronous
        isDisplayActive = true
        onDebugEvent?("HUD display started")
        return display
    }

    /// The session, started, or `GlassesDisplayError.displayInUse` when the Display is not ours.
    ///
    /// Plan KP §8 rule 2: a `paused` session (another app has the Display) is never started again
    /// and never torn down; its watcher follows it back to `started`, and the reading returns to
    /// `.ours` by itself. A start that does not reach `started` (it throws, or the session settles
    /// anywhere else) is a refused start: the session is dropped and the reading is `.inUse` for
    /// `startRefusalExpiry`. A compatibility refusal (the glasses refuse this build) is not that;
    /// it is thrown as itself. Genuinely stopped or idle sessions are rebuilt, as before.
    @discardableResult
    func prepareSession() async throws -> DisplaySessionControl {
        if let session {
            switch session.sessionState {
            case .started:
                return session
            case .paused:
                noteSessionState(.paused)
                throw GlassesDisplayError.displayInUse
            case .stopped, .idle:
                dropSession(stopping: false)   // died underneath us: rebuild from scratch
            case .starting, .stopping:
                break
            }
        }
        if sessionReading.startRefused { throw GlassesDisplayError.displayInUse }

        guard isAvailable else { throw GlassesDisplayError.noDisplay }

        let session: DisplaySessionControl
        if let existing = self.session {
            session = existing
        } else {
            session = try makeSession()
            self.session = session
            watch(session)
        }

        if session.sessionState != .started {
            do {
                try session.start()
            } catch {
                if DATCompatibilityMessage.isSDKRefusal(error) { throw error }
                refuseStart()
                throw GlassesDisplayError.displayInUse
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                let state = session.sessionState
                if state == .started || state == .stopped || state == .paused { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let state = session.sessionState
        noteSessionState(state)
        switch state {
        case .started:
            return session
        case .paused:
            throw GlassesDisplayError.displayInUse
        default:
            refuseStart()
            throw GlassesDisplayError.displayInUse
        }
    }

    private func makeSession() throws -> DisplaySessionControl {
        if let testMakeSession { return try testMakeSession() }
        return DATDisplaySession(try Wearables.shared.createSession(deviceSelector: deviceSelector))
    }

    /// Follow the session's own states for as long as we hold it. A pause that happens while
    /// nothing is rendering is heard at once, so the reading is `.inUse` before the next answer;
    /// `started` again brings it back to `.ours`. The stream finishes at `.stopped`.
    private func watch(_ session: DisplaySessionControl) {
        sessionWatch?.cancel()
        let updates = session.stateUpdates()
        sessionWatch = Task { @MainActor [weak self] in
            for await state in updates {
                guard let self, !Task.isCancelled, self.session === session else { return }
                self.noteSessionState(state)
            }
        }
    }

    private func noteSessionState(_ state: DisplaySessionState?) {
        guard sessionReading.state != state else { return }
        if let state {
            PrivacyLog.device(.hud, .displaySessionRead, state: PrivacyToken(state.rawValue))
        }
        sessionReading.state = state
    }

    private func refuseStart() {
        dropSession()
        refusalGeneration += 1
        let generation = refusalGeneration
        sessionReading.startRefused = true
        onDebugEvent?("HUD display start refused")
        scheduleRefusalExpiry(Self.startRefusalExpiry) { [weak self] in
            guard let self, generation == self.refusalGeneration else { return }
            self.clearStartRefusal()
        }
    }

    private func clearStartRefusal() {
        refusalGeneration += 1
        sessionReading.startRefused = false
    }

    private func dropSession(stopping: Bool = true) {
        sessionWatch?.cancel()
        sessionWatch = nil
        if stopping { session?.stop() }
        session = nil
        display = nil
        isDisplayActive = false
        noteSessionState(nil)
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

#endif
