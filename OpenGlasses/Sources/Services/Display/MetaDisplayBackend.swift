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

    /// Plan KV §6: whether the backend draws a screen's `HUDPicture`. Meta Display: yes. Even G2
    /// (monochrome text cells) and the web mirror: no — they keep the cue line, and a picture is
    /// never handed to them.
    var drawsPictures: Bool { get }
    /// The size of the last picture sent, in bytes as it went to the transport, for the support
    /// report. Nil when the backend sent none or cannot say.
    var lastPictureBytes: Int? { get }
    /// Plan MU §0: the connected glasses' model, which the fit check's reading is kept by. Nil when
    /// the backend cannot say.
    var glassesModel: String? { get }

    /// Plan LC §6: the caption frame (`HUDCaptionBuilder`). The default draws it as a heading (the
    /// speaker) and one body (the rows), which a text-cell backend wraps to its own panel; the Meta
    /// backend draws the three rows.
    func showCaption(_ caption: HUDCaption) async throws

    /// Plan LC §6: whether the backend plays a clip (Meta Display: DAT's `VideoPlayer`). Even G2,
    /// the web mirror and the phone-only build: no, and a task card on them never offers **Watch**.
    var playsVideo: Bool { get }
    /// Play `video` as the lens's whole frame. `onEnded` hears how it ended (it ran out, it was
    /// stopped, or the glasses reported an error), once.
    func playVideo(_ video: HUDVideo, onEnded: @escaping @MainActor (HUDVideoEnding) -> Void) async throws
    /// Stop a clip that is playing. Nothing when none is.
    func stopVideo() async
}

extension GlassesDisplayBackend {
    var drawsPictures: Bool { false }
    var lastPictureBytes: Int? { nil }
    var glassesModel: String? { nil }

    func showCaption(_ caption: HUDCaption) async throws {
        try await showContent(title: caption.speaker, body: HUDCaptionBuilder.body(caption),
                              icon: caption.listening ? .microphone : .none)
    }

    var playsVideo: Bool { false }
    func playVideo(_ video: HUDVideo, onEnded: @escaping @MainActor (HUDVideoEnding) -> Void) async throws {
        throw GlassesDisplayError.noDisplay
    }
    func stopVideo() async {}
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
    /// Let go of a session that ended under us without stopping anything (`stop()` is the
    /// deliberate end). The shared session's hold is handed back either way.
    func relinquish()
}

extension DisplaySessionControl {
    func relinquish() {}
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
    /// The session is shared with the camera (`DeviceSessionCoordinator`): ending the lens hands it
    /// back, and it stops only once the camera has let go too.
    func stop() { DeviceSessionCoordinator.shared.release(.display) }
    func relinquish() { DeviceSessionCoordinator.shared.release(.display) }
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

extension DisplayCapabilityPhase {
    init(_ state: DisplayState) {
        switch state {   // `DisplayState` is @frozen
        case .starting: self = .starting
        case .started: self = .started
        case .stopping: self = .stopping
        case .stopped: self = .stopped
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
/// Session ownership: the `DeviceSession` is borrowed from `DeviceSessionCoordinator` and shared
/// with the camera — the SDK allows one per device, and two of our own locked each other out. A
/// photo crossing from the glasses can stop the Display under the live session (Meta known issue);
/// that is heard here and the service draws the lens again (`onDisplayStoppedUnderSession`).
@MainActor
final class MetaDisplayBackend: GlassesDisplayBackend {

    var onItemSelected: ((String) -> Void)?
    /// Meta render failures throw from the render calls; nothing fires this.
    var onTransportError: ((Error) -> Void)?
    var onDebugEvent: ((String) -> Void)?
    /// True once the display capability is started and content is being shown.
    private(set) var isDisplayActive = false

    /// Plan KV §6: `Image(image:sizePreset: .fill)` above the button row.
    var drawsPictures: Bool { true }
    private(set) var lastPictureBytes: Int?
    /// Plan MU §0: how much every picture is shrunk before it is sent (`LensPictureScale`): the
    /// fit check's factor for the glasses on now, 1 until one is taken. A seam for tests.
    var pictureFactor: @MainActor () -> CGFloat = { LensPictureScale.activeFactor() }

    /// The connected glasses' model (the SDK's device type), for the fit check's reading.
    var glassesModel: String? {
        guard testIsAvailable == nil, WearablesBootstrap.ensureConfigured(),
              let id = deviceSelector.activeDevice,
              let device = Wearables.shared.deviceForIdentifier(id) else { return nil }
        return device.deviceType().rawValue
    }

    /// Lazily initialized after `Wearables.configure()` has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var session: DisplaySessionControl?
    private var display: Display?
    /// A Display we let go of while its session may live on (the camera still holding the shared
    /// session). It was stopped when dropped; the next `addDisplay()` waits for it to reach
    /// `stopped`, because the SDK refuses a second Display on a session while one is active.
    private var retiringDisplay: Display?
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

    /// Plan LC §2.2: the session we held reached `.stopped` without us stopping it — the wearer's
    /// Back gesture or two-finger tap, or the glasses' hands-free mic coming up (iOS #342, #349). The
    /// service reads it as a dismissal and does not reopen the lens for an ambient frame.
    var onSessionEndedByDevice: (() -> Void)?

    /// The Display capability stopped while the session carried on: a photo crossing from the
    /// glasses, which Meta lists as stopping the Display. Not a dismissal; the service draws the
    /// lens again, and the next send restarts the Display and waits for it.
    var onDisplayStoppedUnderSession: (() -> Void)?
    /// Follows the live display's own states (`statePublisher`).
    private var displayStateToken: (any AnyListenerToken)?
    private var displayReachedStarted = false

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
        videoEnded = nil   // Plan LC §6: a frame replaces a clip
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
        try await HUDSendDeadline.run { try await display.send(view) }
    }

    func send(screen: HUDScreen) async throws {
        let display = try await ensureDisplay()
        // Plan LC §6: a screen replaces a clip; the service already knows it left.
        videoEnded = nil
        let view = makeScreenView(screen)
        if screen.hasPictures { lastPictureBytes = Self.pictureBytes(in: view) }
        // Plan LC §2.4: a send that has not come back in `HUDSendDeadline.seconds` has failed.
        try await HUDSendDeadline.run { try await display.send(view) }
    }

    #if DAT_MOCK_DISPLAY
    /// Development only: Developer › Simulated Display › Tall views sends views the HUD's
    /// SDK-free DSL can't express (columns and grids of tappable `FlexBox`es) to measure how the
    /// simulated lens scrolls and focuses them. It goes through this backend's own session and
    /// display (`ensureDisplay()`), the ones `DeviceSessionCoordinator` lends the HUD, so no
    /// second session is made. Compiled only into the mock lane, a Debug build for the Simulator.
    func sendMeasurementView(_ view: FlexBox, deadline: TimeInterval) async throws {
        let display = try await ensureDisplay()
        videoEnded = nil
        try await HUDSendDeadline.run(seconds: deadline) { try await display.send(view) }
    }
    #endif

    /// The encoded size of the picture in a built tree: DAT carries an `Image` as its `uri`.
    /// Plan MG §4: a page's tiles and a strip's slices are pictures inside blocks, so every image
    /// in the tree counts; nil when the tree has none.
    static func pictureBytes(in view: FlexBox) -> Int? {
        let found = images(in: view)
        return found.isEmpty ? nil : found.reduce(0) { $0 + $1.uri.utf8.count }
    }

    private static func images(in view: FlexBox) -> [Image] {
        view.children.flatMap { child -> [Image] in
            if let image = child as? Image { return [image] }
            if let box = child as? FlexBox { return images(in: box) }
            return []
        }
    }

    // MARK: - Captions and clips (Plan LC §6)

    /// The caption screen: an items-less frame, top-aligned, through the same tree as any screen.
    func showCaption(_ caption: HUDCaption) async throws {
        try await send(screen: HUDCaptionBuilder.screen(caption))
    }

    var playsVideo: Bool { true }

    /// The clip's ending callback, once: cleared when it fires or another frame replaces the clip.
    private var videoEnded: (@MainActor (HUDVideoEnding) -> Void)?

    /// Send `VideoPlayer` as the root view. The Display fetches the URL itself. Playback events
    /// arrive on `Display.onPlaybackEvent`; an ended, stopped or error event ends the clip once, and
    /// so does a `VideoError` reported through the player's own `onError`.
    func playVideo(_ video: HUDVideo, onEnded: @escaping @MainActor (HUDVideoEnding) -> Void) async throws {
        let display = try await ensureDisplay()
        videoEnded = onEnded
        display.onPlaybackEvent = { [weak self] event in
            let ending: HUDVideoEnding?
            switch event.type {
            case .ended: ending = .ended
            case .stopped: ending = .stopped
            case .error: ending = .failed
            case .started, .unknown: ending = nil
            @unknown default: ending = nil
            }
            guard let ending else { return }
            Task { @MainActor in self?.endVideo(ending) }
        }
        let player = VideoPlayer(provider: .uri(video.url.absoluteString), codec: .mp4,
                                 onError: { [weak self] _ in
                                     Task { @MainActor in self?.endVideo(.failed) }
                                 })
        onDebugEvent?("HUD clip started")
        try await HUDSendDeadline.run { try await display.send(player) }
    }

    func stopVideo() async {
        guard videoEnded != nil, let display else { return }
        await display.sendVideoStop()
    }

    private func endVideo(_ ending: HUDVideoEnding) {
        guard let ended = videoEnded else { return }
        videoEnded = nil
        display?.onPlaybackEvent = nil
        onDebugEvent?("HUD clip \(ending.rawValue)")
        ended(ending)
    }

    func clear() async throws {
        // Nothing to clear if we never started a session.
        guard let display else { return }
        videoEnded = nil   // Plan LC §6: a clear replaces a clip
        // DAT 0.8.0: explicit clear instead of sending an empty FlexBox.
        try await display.clearDisplay()
    }

    func shutdown() async {
        videoEnded = nil
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
    ///
    /// `onSelect`, when given, is where a button's press goes instead of this backend's
    /// `onItemSelected`: the phone preview's own presses (Plan KV P3). The lens never passes it.
    func makeScreenView(_ screen: HUDScreen,
                        onSelect: (@MainActor @Sendable (String) -> Void)? = nil) -> FlexBox {
        // Plan MU §0: never two pictures side by side (real glasses drew a row's first picture
        // across the whole view and nothing of the rest).
        let screen = screen.onePictureARow()
        let factor = pictureFactor()
        // Pre-shape all text and presentation here (MainActor context) so the
        // result-builder closure below never references anything actor-isolated.
        // Each button model carries only Sendable values — never the HUDItem, whose
        // `action` closure isn't Sendable; selection routes back by id.
        let headingText = screen.title.flatMap { $0.isEmpty ? nil : HUDTextShaper.condense($0, max: HUDTextShaper.maxTitleLength) }
        let lineModels = screen.lines.map { line in
            (text: HUDTextShaper.condense(line.text), iconName: line.icon.metaIconName,
             style: line.emphasis.textStyle, color: line.emphasis.textColor)
        }
        // Plan LC §2.1: exactly one button carries `.actionRole(.primary)`, so the glasses focus it
        // when the frame first renders (and again on every re-send, which resets focus).
        let focusID = screen.resolvedFocusItemID
        // A secondary button with an icon can be drawn as the icon alone, losing its label, so
        // only a primary button keeps its icon (`LensButtonIconPolicy`).
        let buttonModels = screen.items.map { item in
            (id: item.id, label: HUDTextShaper.condense(item.label, max: HUDTextShaper.maxTitleLength),
             style: item.style.buttonStyle,
             iconName: LensButtonIconPolicy.icon(item.icon, style: item.style).metaIconName,
             focused: item.id == focusID)
        }
        // Plan KV §6: the page view's picture, built here so the builder closure captures only the
        // Sendable `Image`, never the `UIImage`. It is drawn at the box the frame leaves it
        // (`LensPageFrame.pictureBox`), the column's full width, so `.fill` draws it one lens pixel
        // per image pixel and the lines, the picture and the button row all fit on the lens.
        let picture = screen.picture.map { Self.lensImage($0, factor: factor) }
        // Plan LC §6: a turn arrow leads its guidance line; everything else draws under the lines.
        let pictureLeads = screen.picture?.placement == .aboveLines
        // Under a button row, room for the focused button's glow (`LensPageFrame`): with the 12 px
        // margin the glow reached past the lens, and the lens scrolled every frame up by 20 px.
        let bottomPadding = LensPageFrame.bottomPadding(hasButtons: !buttonModels.isEmpty && screen.trailingFlow.isEmpty)
        // Plan MG §2: the blocks before and after the button row, built here so the builder closure
        // captures only Sendable components. A press on one routes back by its id, as a button's.
        let route: @Sendable (String) -> Void = { [weak self] id in
            Task { @MainActor in
                if let onSelect { onSelect(id) } else { self?.onItemSelected?(id) }
            }
        }
        let flowComponents = Self.flowComponents(screen.flow, factor: factor, route: route)
        let trailingComponents = Self.flowComponents(screen.trailingFlow, factor: factor, route: route)

        return FlexBox(
            direction: .column,
            spacing: 6,
            alignment: .start,
            padding: EdgeInsets(top: 12, bottom: bottomPadding, leading: 12, trailing: 12)
        ) {
            if let headingText {
                Text(headingText, style: .heading, color: .primary)
            }
            if pictureLeads, let picture {
                picture
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
            for component in flowComponents {
                component
            }
            if !pictureLeads, let picture {
                picture
            }
            // DAT 0.9.0 `ButtonGroup`: the sanctioned container for button rows (bare
            // buttons as loose FlexBox children predate it; flex params on a Button wrap
            // it in a label-clipping FlexChildWrapper, which the group avoids).
            if !buttonModels.isEmpty {
                ButtonGroup(alignment: .center) {
                    for button in buttonModels {
                        let id = button.id
                        let onClick: @Sendable () -> Void = { [weak self] in
                            Task { @MainActor in
                                if let onSelect { onSelect(id) } else { self?.onItemSelected?(id) }
                            }
                        }
                        if button.focused {
                            Button(label: button.label, style: button.style, iconName: button.iconName,
                                   onClick: onClick)
                                .actionRole(.primary)
                        } else {
                            Button(label: button.label, style: button.style, iconName: button.iconName,
                                   onClick: onClick)
                        }
                    }
                }
            }
            for component in trailingComponents {
                component
            }
        }
    }

    /// Plan MG §2: a screen's flow as DAT components: a line as `Text`, a row of blocks as tappable
    /// `FlexBox`es — on a card (`.background(.card)`, the only way the lens shows focus on a box) or
    /// plain (a strip's seamless slices). One block takes the column's width; several sit in a row
    /// 8 px apart, each at its picture's own size (`.fill` draws one image pixel per lens pixel).
    private static func flowComponents(_ flow: [HUDFlowElement], factor: CGFloat,
                                       route: @escaping @Sendable (String) -> Void) -> [any ViewComponent] {
        flow.map { element -> any ViewComponent in
            switch element {
            case .line(let line):
                return Text(HUDTextShaper.condense(line.text), style: line.emphasis.textStyle,
                            color: line.emphasis.textColor)
            case .blocks(let blocks):
                let boxes = blocks.map { blockComponent($0, stretch: blocks.count == 1, factor: factor, route: route) }
                if boxes.count == 1, let only = boxes.first { return only }
                return FlexBox(direction: .row, spacing: LensPageFrame.tileGapPixels, alignment: .start) {
                    for box in boxes { box }
                }
            }
        }
    }

    private static func blockComponent(_ block: HUDBlock, stretch: Bool, factor: CGFloat,
                                       route: @escaping @Sendable (String) -> Void) -> FlexBox {
        let texts = block.lines.map {
            Text(HUDTextShaper.condense($0.text), style: $0.emphasis.textStyle, color: $0.emphasis.textColor)
        }
        let image = block.picture.map { lensImage($0, factor: factor) }
        let card = block.style == .card
        // A text block sits inside the card's padding; a picture tile fills its card, at the size
        // it was drawn for.
        let padding = card && block.picture == nil ? LensPageFrame.cardPaddingPixels : 0
        var box = FlexBox(direction: .column, spacing: 0, alignment: .start, padding: EdgeInsets(all: padding)) {
            for text in texts { text }
            if let image { image }
        }
        if stretch { box = box.alignSelf(.stretch) }
        if card { box = box.background(.card) }
        let id = block.id
        return box.onTap { route(id) }
    }

    /// Plan MU §0: the one place a picture becomes the lens's `Image`: shrunk by the glasses'
    /// picture factor first (`LensPictureScale`), unless it is one the fit check measures with. At
    /// factor 1 the image goes exactly as drawn.
    static func lensImage(_ picture: HUDPicture, factor: CGFloat) -> Image {
        let image = picture.scalesForLens ? LensPictureScale.scaled(picture.image, by: factor) : picture.image
        return Image(image: image, sizePreset: .fill)
    }

    /// Test helper (Plan MG §2): the `onTap` actions of the tappable blocks in `screen`'s rendered
    /// tree, in column order.
    func testBlockActions(for screen: HUDScreen) -> [() -> Void] {
        func taps(_ component: any ViewComponent) -> [@Sendable () -> Void] {
            guard let box = component as? FlexBox else { return [] }
            return (box.onClick.map { [$0] } ?? []) + box.children.flatMap(taps)
        }
        return makeScreenView(screen).children.flatMap(taps).map { onClick in { onClick() } }
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
            if display.state != .started { try await awaitStarted(display) }
            return display
        }
        // The session is shared with the camera (`DeviceSessionCoordinator`), so a Display we
        // dropped may still be winding down on it: wait for it, or `addDisplay()` is refused with
        // `capabilityAlreadyActive` (build 717: every frame after one failed draw).
        if let retiring = retiringDisplay {
            let (outcome, waited) = try await DisplayStopWait.wait { DisplayCapabilityPhase(retiring.state) }
            PrivacyLog.device(.hud, .displayCapabilityRead, state: PrivacyToken(outcome.rawValue),
                              detail: PrivacyToken("retired"), count: Int((waited * 1000).rounded()))
            retiringDisplay = nil
        }
        // `addDisplay()` throws DeviceSessionError; surface failures via the render-error path
        // (which tears down and rebuilds a fresh session).
        let display = try session.addDisplay()
        self.display = display
        watchDisplay(display)
        display.start()  // DAT 0.8.0: Display.start() is synchronous; the state follows
        try await awaitStarted(display)
        isDisplayActive = true
        onDebugEvent?("HUD display started")
        return display
    }

    /// Listen to the display's own states before it is started, as Meta's sample does.
    private func watchDisplay(_ display: Display) {
        cancelDisplayWatch()
        displayReachedStarted = false
        displayStateToken = display.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.displayStateChanged(display, to: DisplayCapabilityPhase(state)) }
        }
    }

    private func displayStateChanged(_ display: Display, to phase: DisplayCapabilityPhase) {
        guard self.display === display else { return }   // a display we have let go of
        switch phase {
        case .started:
            displayReachedStarted = true
        case .stopped:
            guard displayReachedStarted, session?.sessionState == .started else { return }
            displayReachedStarted = false
            isDisplayActive = false
            PrivacyLog.device(.hud, .displayCapabilityRead, state: PrivacyToken("stoppedUnderSession"))
            onDebugEvent?("HUD display stopped under a live session")
            onDisplayStoppedUnderSession?()
        case .starting, .stopping:
            break
        }
    }

    private func cancelDisplayWatch() {
        if let token = displayStateToken {
            displayStateToken = nil
            Task { await token.cancel() }
        }
    }

    /// Hold the first send until the capability is `started` (`DisplayStartWait`). A display that
    /// stops or never gets there throws `displayDidNotStart`, which the render-error path reads as
    /// a failure and rebuilds from — never a send into a display that is not ready. A display that
    /// still reads `stopped` (waking from the glasses' idle sleep) is given the whole allowance;
    /// one this backend has let go of meanwhile is not waited for.
    private func awaitStarted(_ display: Display) async throws {
        let (outcome, waited) = try await DisplayStartWait.wait(
            phase: { DisplayCapabilityPhase(display.state) },
            isCurrent: { [weak self] in self?.display === display }
        )
        PrivacyLog.device(.hud, .displayCapabilityRead, state: PrivacyToken(outcome.rawValue),
                          count: Int((waited * 1000).rounded()))
        guard outcome == .started else {
            onDebugEvent?("HUD display did not start (\(outcome.rawValue))")
            throw GlassesDisplayError.displayDidNotStart
        }
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
                // The camera may have started the shared session a moment ago: wait, don't restart.
                if session.sessionState != .starting { try session.start() }
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
        // Borrowed, and shared with the camera: one session per pair (`DeviceSessionCoordinator`).
        guard let shared = try DeviceSessionCoordinator.shared.acquire(.display) as? DeviceSession else {
            throw GlassesDisplayError.sessionUnavailable
        }
        return DATDisplaySession(shared)
    }

    /// Follow the session's own states for as long as we hold it. A pause that happens while
    /// nothing is rendering is heard at once, so the reading is `.inUse` before the next answer;
    /// `started` again brings it back to `.ours`. The stream finishes at `.stopped`.
    private func watch(_ session: DisplaySessionControl) {
        sessionWatch?.cancel()
        let updates = session.stateUpdates()
        sessionWatch = Task { @MainActor [weak self] in
            var reachedStarted = false
            for await state in updates {
                guard let self, !Task.isCancelled, self.session === session else { return }
                self.noteSessionState(state)
                if state == .started { reachedStarted = true }
                // Plan LC §2.2: `dropSession` cancels this watch before it stops the session, so a
                // `.stopped` heard here, after the session was up, is one the app did not ask for.
                // A start that never got there is a refused start (`prepareSession`), not this.
                if state == .stopped, reachedStarted {
                    self.onDebugEvent?("HUD display session ended by the glasses")
                    self.dropSession(stopping: false)
                    self.onSessionEndedByDevice?()
                    return
                }
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
        cancelDisplayWatch()
        // Stop the Display before handing the session back. The session is shared with the
        // camera, so handing it back no longer stops it, and a Display left running on it made
        // every later `addDisplay()` fail with `capabilityAlreadyActive` until the camera let go.
        retireDisplay()
        if stopping { session?.stop() } else { session?.relinquish() }
        session = nil
        display = nil
        isDisplayActive = false
        noteSessionState(nil)
    }

    /// Stop the held Display (synchronous; its state follows) and keep it until the next
    /// `addDisplay()` has seen it reach `stopped`. One already stopping or stopped is only kept.
    private func retireDisplay() {
        guard let display else { return }
        if DisplayCapabilityPhase.needsStop(DisplayCapabilityPhase(display.state)) { display.stop() }
        retiringDisplay = display
    }
}

// MARK: - Phone mirror

extension GlassesDisplayService {
    /// Build the SDK view tree for `screen` for the on-phone preview/mirror
    /// (`HUDPreviewView`). Session-free; the returned tree's button taps go to `onSelect`, and
    /// nowhere without one. Shares `makeScreenView` with the on-glasses path so the phone mirror
    /// is a single source of truth. Lives here so the service file stays SDK-free (Plan AH).
    static func previewFlexBox(for screen: HUDScreen,
                               onSelect: (@MainActor @Sendable (String) -> Void)? = nil) -> FlexBox {
        MetaDisplayBackend().makeScreenView(screen, onSelect: onSelect)
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
        case .weather: return .cloud
        case .clock: return .clock
        // DAT 1.0 has no microphone glyph: the three-dot bubble ("someone is speaking") is the
        // nearest the stable icon set offers for live capture.
        case .microphone: return .threeDotSpeechBubble
        case .music: return .musicNote
        case .video: return .triangleRightCircle
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
