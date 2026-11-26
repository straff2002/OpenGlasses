#if DAT_EXPERIMENTAL
import Foundation

// Plan MU §7 (P6). Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// Listens to the Neural Band while the manual page view is on the lens, and hands each input to
/// the page view (`LensPageSession.handleBand`), which acts only on left and right
/// (`LensBandNavMap`): a close-up's halves, the page before or after at fit width, a spoken zoom
/// half a crop, and the pages of the whole page and of reading mode. The decision is the page
/// view's, in ordinary code; this only opens and closes the channel.
///
/// - **Only while it can matter.** The channel is opened when the page view itself is on the lens,
///   a pair's link is connected, the Inputs probe is not running and the wearer's switch lets the
///   feature run (`DATExperimentalPolicy`), and closed as soon as any of those stops holding.
/// - **The band's swipes and presses only, Back left to Meta** (`LensBandNavConfiguration`).
/// - **A failed or ended channel is not asked for again for the same view**, so a pair that refuses
///   Inputs costs one attempt a view, not one a moment.
/// - **The probe comes first.** Both add the session's one Inputs capability, so a probe start
///   waits for this to hand it back (`yield`), and nothing opens here until the probe is done.
@MainActor
final class LensBandNavService {
    private let source: InputsSource
    private let isEnabled: () -> Bool
    private let onInput: (GlassesInput) -> Void
    private let onListening: () -> Void
    private let onFailed: () -> Void

    private var connected: [String] = []
    private var viewOnLens = false
    private var probeRunning = false
    /// A probe start is waiting for the capability.
    private var yielding = false
    /// The channel failed or ended for the view that is up: not asked for again until it closes.
    private var heldOffForThisView = false

    private var channel: InputsChannel?
    private var deviceId: String?
    private var openTask: Task<Void, Never>?
    /// Bumped at every open and every stop, so a late callback from an old channel is ignored.
    private var run = 0
    private var listening = false

    init(source: InputsSource,
         isEnabled: @escaping () -> Bool,
         onInput: @escaping (GlassesInput) -> Void,
         onListening: @escaping () -> Void = {},
         onFailed: @escaping () -> Void = {}) {
        self.source = source
        self.isEnabled = isEnabled
        self.onInput = onInput
        self.onListening = onListening
        self.onFailed = onFailed
    }

    /// A channel is open or being opened.
    var isListening: Bool { channel != nil || openTask != nil }

    func update(connectedDeviceIds ids: [String]) {
        connected = ids
        refresh()
    }

    /// Whether the page view itself (not its cue) is what the lens holds.
    func update(viewOnLens: Bool) {
        if !viewOnLens { heldOffForThisView = false }
        self.viewOnLens = viewOnLens
        refresh()
    }

    func update(probeRunning: Bool) {
        self.probeRunning = probeRunning
        if !probeRunning { yielding = false }
        refresh()
    }

    /// Hands the capability back before a probe run adds it: stops the channel and waits for an
    /// open in flight to finish (and remove what it added), so the probe never shares it.
    func yield() async {
        yielding = true
        let pending = openTask
        stop()
        await pending?.value
    }

    /// Plan NB §6: a wrist gesture's switch changed, so the channel is asked for again with or
    /// without the drag stream. A channel held off for this view stays held off.
    func reopen() {
        stop()
        refresh()
    }

    /// Opens or closes the channel to match what is true now. Also the wearer's switch changing.
    func refresh() {
        let wanted = viewOnLens && !probeRunning && !yielding && !heldOffForThisView
            && !connected.isEmpty && isEnabled()
        if !wanted {
            stop()
        } else if let deviceId, !connected.contains(deviceId) {
            stop()
            refresh()
        } else if channel == nil, openTask == nil {
            open(deviceId: connected[0])
        }
    }

    private func open(deviceId id: String) {
        run += 1
        let thisRun = run
        deviceId = id
        listening = false
        let source = source
        let handlers = handlers(for: thisRun)
        openTask = Task { @MainActor [weak self] in
            do {
                let opened = try await source.open(deviceId: id, handlers: handlers)
                guard let self, self.run == thisRun else {
                    // Stopped while Inputs was being added: take it off again.
                    opened.stop()
                    return
                }
                self.openTask = nil
                self.channel = opened
                // `.active` may have come before the state listener was attached.
                if opened.state == .active { self.becameActive() }
            } catch {
                guard let self, self.run == thisRun else { return }
                self.openTask = nil
                self.deviceId = nil
                self.failed()
            }
        }
    }

    private func stop() {
        run += 1
        openTask = nil
        channel?.stop()
        channel = nil
        deviceId = nil
        listening = false
    }

    private func becameActive() {
        guard !listening else { return }
        listening = true
        onListening()
    }

    private func failed() {
        heldOffForThisView = true
        stop()
        onFailed()
    }

    private func handlers(for thisRun: Int) -> InputsChannelHandlers {
        InputsChannelHandlers(
            onInput: { [weak self] input in
                guard let self, self.run == thisRun else { return }
                self.onInput(input)
            },
            onState: { [weak self] state in
                guard let self, self.run == thisRun, state == .active else { return }
                self.becameActive()
            },
            onFailure: { [weak self] _ in
                guard let self, self.run == thisRun else { return }
                self.failed()
            },
            onEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.heldOffForThisView = true
                self.stop()
            },
            onInputsEnded: { [weak self] in
                guard let self, self.run == thisRun else { return }
                self.heldOffForThisView = true
                self.stop()
            })
    }
}
#endif
