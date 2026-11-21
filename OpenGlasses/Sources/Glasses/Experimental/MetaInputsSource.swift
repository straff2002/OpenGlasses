#if DAT_EXPERIMENTAL
import Foundation
import MWDATCore
import MWDATInputs

// Plan JV P2: the only code that touches the SDK's [Experimental] Inputs. Compiled only in a
// project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight only, never submitted for review).

/// The one configuration the probe ever asks for: the touchpad and the Neural Band (presses,
/// swipes and drag), Back left to Meta. Never the capture button (Meta's camera), never the action
/// button and never `consumeBack`. Built from `InputsProbePolicy`, and
/// `DATExperimentalGuardTests` pins this line as written.
enum InputsProbeConfiguration {
    static let sdk = InputsConfiguration(sources: [.captouch, .neuralBand, .neuralBandDrag], consumeBack: false)

    /// What `sdk` asks for, in the app's own words (for the flagged tests).
    static var origins: Set<GlassesInputOrigin> { Set(sdk.sources.map(MetaInputsSource.origin)) }
    static var consumesBack: Bool { sdk.consumeBack }
}

/// Inputs from Meta's SDK, on the shared `DeviceSessionCoordinator` session as its `.inputs`
/// capability, beside the camera and the lens when they are on: the session is created bound to
/// the connected device when no one holds it, started unless it already is (or is starting), and
/// the capability added once it is `started`. Handing it back stops the session only when the
/// probe was its last holder.
struct MetaInputsSource: InputsSource {
    var coordinator: DeviceSessionCoordinator = .shared
    /// How long the session has to reach `started`.
    var startDeadline: Duration = .seconds(20)

    func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel {
        // The link is up, so the SDK has been configured; this only makes that the permission to
        // touch `Wearables.shared`, as everywhere else.
        guard WearablesBootstrap.ensureConfigured() else { throw InputsProbeFailure.sessionUnavailable }
        let handle: DeviceSessionHandle
        do {
            handle = try coordinator.acquire(.inputs, deviceId: deviceId)
        } catch {
            throw InputsProbeFailure.sessionUnavailable
        }
        guard let session = handle as? DeviceSession else {
            coordinator.release(.inputs)
            throw InputsProbeFailure.sessionUnavailable
        }
        do {
            if session.state != .started {
                // The camera or the lens may have started the shared session a moment ago; it is
                // waited for, never started twice.
                if session.state != .starting {
                    do { try session.start() } catch { throw InputsProbeFailure.sessionNotStarted }
                }
                let deadline = ContinuousClock.now + startDeadline
                while session.state != .started, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            guard session.state == .started else { throw InputsProbeFailure.sessionNotStarted }
            let added: Inputs?
            do {
                added = try session.addInputs(configuration: InputsProbeConfiguration.sdk)
            } catch {
                throw InputsProbeFailure.addFailed
            }
            guard let inputs = added else { throw InputsProbeFailure.capabilityNotAdded }
            return MetaInputsChannel(session: session, inputs: inputs, coordinator: coordinator, handlers: handlers)
        } catch {
            // Nothing was added: hand the session back (the last holder out stops it).
            coordinator.release(.inputs)
            throw error
        }
    }

    // MARK: - The SDK's words in the app's

    nonisolated static func origin(_ source: InputSource) -> GlassesInputOrigin {
        switch source {
        case .captouch: return .captouch
        case .neuralBand: return .neuralBand
        case .captureButton: return .captureButton
        case .actionButton: return .actionButton
        case .neuralBandDrag: return .neuralBandDrag
        case .unknown: return .unknown
        }
    }

    /// The kind, with its direction or press type. A drag keeps its phase only; its coordinates
    /// are never read.
    nonisolated static func input(_ event: InputEvent) -> GlassesInput {
        let kind: GlassesInputKind
        switch event {
        case .nav(let direction, _, _):
            switch direction {
            case .up: kind = .nav(.up)
            case .down: kind = .nav(.down)
            case .left: kind = .nav(.left)
            case .right: kind = .nav(.right)
            }
        case .select:
            kind = .select
        case .back:
            kind = .back
        case .button(let button, _, _):
            switch button {
            case .action: kind = .actionButton
            }
        case .capture(let press, _, _):
            switch press {
            case .shortPress: kind = .capture(.shortPress)
            case .hold: kind = .capture(.hold)
            case .doublePress: kind = .capture(.doublePress)
            }
        case .drag(let action, _, _, _, _, _, _):
            switch action {
            case .down: kind = .drag(.down)
            case .move: kind = .drag(.move)
            case .up: kind = .drag(.up)
            }
        @unknown default:
            kind = .unknown
        }
        return GlassesInput(kind: kind, origin: origin(event.source))
    }

    /// Not frozen: a case added in a later SDK is `.unknown` until it is read and named here.
    nonisolated static func state(_ state: InputsState) -> InputsProbeState {
        switch state {
        case .inactive: return .inactive
        case .activating: return .activating
        case .active: return .active
        case .deactivating: return .deactivating
        @unknown default: return .unknown
        }
    }

    /// Not frozen: a case added in a later SDK is `.unknown` until it is read and named here.
    nonisolated static func failure(_ error: InputsError) -> InputsProbeFailure {
        switch error {
        case .permissionDenied: return .permissionDenied
        case .connectionClosed: return .connectionClosed
        case .activationTimeout: return .activationTimeout
        case .activationFailed: return .activationFailed
        case .capabilityUnavailable: return .capabilityUnavailable
        case .deviceDisconnected: return .deviceDisconnected
        case .communicationError: return .communicationError
        @unknown default: return .unknown
        }
    }
}

/// The capability while the probe holds it: its state and error listeners in a `ListenerTokenBag`,
/// its event stream and the session's state stream each read by a task, all ended together.
///
/// The listeners are attached here, straight after `addInputs` returns: adding the capability
/// already began activation and neither publisher replays. The bag lives as long as the channel,
/// so the callbacks last as long as the probe holds it.
@MainActor
final class MetaInputsChannel: InputsChannel {
    private let session: DeviceSession
    private let inputs: Inputs
    private let coordinator: DeviceSessionCoordinator
    private let tokens = ListenerTokenBag()
    private var eventsTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var stopped = false

    init(session: DeviceSession, inputs: Inputs, coordinator: DeviceSessionCoordinator,
         handlers: InputsChannelHandlers) {
        self.session = session
        self.inputs = inputs
        self.coordinator = coordinator
        let onState = handlers.onState
        let onFailure = handlers.onFailure
        inputs.statePublisher.listen { state in
            let mapped = MetaInputsSource.state(state)
            Task { @MainActor in onState(mapped) }
        }.store(in: tokens)
        inputs.errorPublisher.listen { error in
            let mapped = MetaInputsSource.failure(error)
            Task { @MainActor in onFailure(mapped) }
        }.store(in: tokens)
        // Per-event work stays small: the SDK keeps only the newest 64 and drops the oldest.
        let events = inputs.events
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                handlers.onInput(MetaInputsSource.input(event))
            }
            // The stream finishes when the capability is removed (our own stop), the glasses are
            // taken off, or a terminal error occurs.
            guard !Task.isCancelled, let self, !self.stopped else { return }
            handlers.onInputsEnded()
        }
        // The session's state stream finishes once it reaches `.stopped` (DAT 0.9.0).
        let states = session.stateStream()
        sessionTask = Task { @MainActor [weak self] in
            for await _ in states {}
            // The coordinator lends an ended session to no one (`hasEnded`), so nothing is reset
            // here: the probe is told and hands its hold back.
            guard !Task.isCancelled, let self, !self.stopped else { return }
            handlers.onEnded()
        }
    }

    var state: InputsProbeState { MetaInputsSource.state(inputs.state) }

    /// Also the way out after an error: a failed capability stays attached until it is removed.
    func stop() {
        guard !stopped else { return }
        stopped = true
        eventsTask?.cancel()
        sessionTask?.cancel()
        try? session.removeInputs()
        coordinator.release(.inputs)
        let tokens = tokens
        Task { await tokens.cancelAll() }
    }
}
#endif
