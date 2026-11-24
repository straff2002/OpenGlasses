#if DAT_EXPERIMENTAL
import Foundation

// Plan NB §6 (P2). Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1
// (TestFlight only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// The wrist gestures on the manual page view: pinch and twist to zoom, and pinch and move the
/// arm to pan, each its own switch. Hosts `LensWristGestures` (pure, every build): the band's
/// inputs (from the page view's band channel, with its drag stream while a gesture is on) open and
/// close the clutch, the band's motion (Meta's Motion, opened here) moves the twist and the arm,
/// and the rungs and steps go to the page view (`LensPageSession.handleTwist` / `handleArmPan`),
/// which decides what they do. As `LensBandNavService`:
///
/// - **Only while it can matter.** Motion is opened when the page view itself is on the lens in a
///   view a gesture can change (the whole page, a close-up or a zoom for the twist; a close-up or
///   a zoom for the pan), a pair's link is connected, no probe runs and a switch lets a gesture run,
///   and closed as soon as any of those stops holding.
/// - **A failed or ended channel is not asked for again while the page view stays up.**
/// - **The probes come first** (`yield`): the Motion probe adds the session's one Motion capability.
@MainActor
final class LensWristGestureService {

    /// What the page view is asked for.
    struct Sink {
        var twist: (TwistRung) -> Void
        var pan: (LensPageViewport.Step) -> Void
        var clutchOpened: () -> Void
        var clutchClosed: () -> Void
        var listening: () -> Void = {}
        var failed: () -> Void = {}
    }

    private let source: WristMotionSource
    private let switches: () -> LensWristGestures.Switches
    private let sink: Sink
    private let clock: () -> ContinuousClock.Instant

    private var engine = LensWristGestures()
    private var connected: [String] = []
    /// The view on the lens while the page view holds it; nil otherwise.
    private var view: HUDPageViewState.View?
    private var probeRunning = false
    private var yielding = false
    private var heldOffForThisView = false

    private var channel: MotionChannel?
    private var deviceId: String?
    private var openTask: Task<Void, Never>?
    private var run = 0
    private var listening = false
    private var samplesHeard = 0

    init(source: WristMotionSource,
         switches: @escaping () -> LensWristGestures.Switches,
         sink: Sink,
         clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.source = source
        self.switches = switches
        self.sink = sink
        self.clock = clock
    }

    var isListening: Bool { channel != nil || openTask != nil }

    /// Whether either gesture's switch is on: the band channel asks for its drag stream only then.
    var wantsDrag: Bool {
        let now = switches()
        return now.twist || now.pan
    }

    /// Whether a gesture that is switched on can change `view`.
    static func canChange(_ view: HUDPageViewState.View?, switches: LensWristGestures.Switches) -> Bool {
        switch view {
        case .whole?: return switches.twist
        case .closeUp?, .zoomed?: return switches.twist || switches.pan
        case .rows?, .reading?, nil: return false
        }
    }

    func update(connectedDeviceIds ids: [String]) {
        connected = ids
        refresh()
    }

    /// The view the page view shows while it holds the lens; nil when it does not.
    func update(view: HUDPageViewState.View?) {
        if view == nil { heldOffForThisView = false }
        self.view = view
        refresh()
    }

    func update(probeRunning: Bool) {
        self.probeRunning = probeRunning
        if !probeRunning { yielding = false }
        refresh()
    }

    /// Hands Motion back before a probe run adds it.
    func yield() async {
        yielding = true
        let pending = openTask
        stop()
        await pending?.value
    }

    /// One input from the band's channel: the clutch's drag bursts and selects.
    func handleBandInput(_ input: GlassesInput) {
        guard isListening else { return }
        apply(engine.input(input, at: clock(), switches: switches()))
    }

    func refresh() {
        let wanted = Self.canChange(view, switches: switches()) && !probeRunning && !yielding
            && !heldOffForThisView && !connected.isEmpty
        if !wanted {
            stop()
        } else if let deviceId, !connected.contains(deviceId) {
            stop()
            refresh()
        } else if channel == nil, openTask == nil {
            open(deviceId: connected[0])
        }
    }

    private func apply(_ outputs: [LensWristGestures.Output]) {
        for output in outputs {
            switch output {
            case .clutchOpened: sink.clutchOpened()
            case .clutchClosed: sink.clutchClosed()
            case .rung(let rung): sink.twist(rung)
            case .pan(let step): sink.pan(step)
            }
        }
    }

    private func open(deviceId id: String) {
        run += 1
        let thisRun = run
        deviceId = id
        listening = false
        samplesHeard = 0
        let source = source
        let handlers = handlers(for: thisRun)
        openTask = Task { @MainActor [weak self] in
            do {
                let opened = try await source.open(deviceId: id, handlers: handlers)
                guard let self, self.run == thisRun else {
                    opened.stop()
                    return
                }
                self.openTask = nil
                self.channel = opened
                if opened.state == .started { self.becameActive() }
            } catch {
                guard let self, self.run == thisRun else { return }
                self.openTask = nil
                self.deviceId = nil
                let failure = (error as? MotionChannelFailure) ?? .unknown
                self.failed(failure)
            }
        }
    }

    private func stop() {
        let wasOpen = channel != nil
        run += 1
        openTask = nil
        channel?.stop()
        channel = nil
        deviceId = nil
        if engine.clutch.isOpen { sink.clutchClosed() }
        engine = LensWristGestures()
        if wasOpen {
            PrivacyLog.device(.hud, .lensWristChannel, state: PrivacyToken("stopped"), count: samplesHeard)
        }
        listening = false
    }

    private func becameActive() {
        guard !listening else { return }
        listening = true
        PrivacyLog.device(.hud, .lensWristChannel, state: PrivacyToken("active"))
        sink.listening()
    }

    private func failed(_ failure: MotionChannelFailure) {
        heldOffForThisView = true
        stop()
        PrivacyLog.device(.hud, .lensWristChannel, state: PrivacyToken("failed"), reason: PrivacyToken(failure.rawValue))
        sink.failed()
    }

    private func handlers(for thisRun: Int) -> MotionChannelHandlers {
        MotionChannelHandlers(
            onSample: { [weak self] sample in
                guard let self, self.run == thisRun else { return }
                self.samplesHeard += 1
                self.becameActive()
                self.apply(self.engine.sample(sample, at: self.clock()))
            },
            onOtherSample: { _ in },
            onState: { [weak self] state in
                guard let self, self.run == thisRun, state == .started else { return }
                self.becameActive()
            },
            onFailure: { [weak self] failure in
                guard let self, self.run == thisRun else { return }
                self.failed(failure)
            },
            onEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.heldOffForThisView = true
                self.stop()
            })
    }
}
#endif
