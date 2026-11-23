#if DAT_EXPERIMENTAL
import Foundation
import MWDATCore
import MWDATMotion

// Plan NB §5: the only code that touches the SDK's [Experimental] Motion. Compiled only in a
// project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight only, never submitted for review).

/// The one configuration Motion is ever added with: 30 Hz (Plan NB decision 8; 60 Hz buys nothing
/// at one send at a time). `DATExperimentalGuardTests` pins this line as written.
enum WristMotionConfiguration {
    static let sdk = MotionConfiguration(samplingRate: .hz30)
}

/// Motion from Meta's SDK, on the shared `DeviceSessionCoordinator` session as its `.motion`
/// capability, beside the camera, the lens and Inputs: the session is created bound to the
/// connected device when no one holds it, started unless it already is (or is starting), and the
/// capability added once it is `started` (`addMotion` returns nil on a session not started), then
/// started. Only the Neural Band's samples are handed on; the rest are counted.
struct MetaMotionSource: WristMotionSource {
    var coordinator: DeviceSessionCoordinator = .shared
    /// How long the session has to reach `started`.
    var startDeadline: Duration = .seconds(20)

    func open(deviceId: String, handlers: MotionChannelHandlers) async throws -> MotionChannel {
        guard WearablesBootstrap.ensureConfigured() else { throw MotionChannelFailure.sessionUnavailable }
        let handle: DeviceSessionHandle
        do {
            handle = try coordinator.acquire(.motion, deviceId: deviceId)
        } catch {
            throw MotionChannelFailure.sessionUnavailable
        }
        guard let session = handle as? DeviceSession else {
            coordinator.release(.motion)
            throw MotionChannelFailure.sessionUnavailable
        }
        do {
            if session.state != .started {
                // Another holder may have started the shared session a moment ago; it is waited
                // for, never started twice.
                if session.state != .starting {
                    do { try session.start() } catch { throw MotionChannelFailure.sessionNotStarted }
                }
                let deadline = ContinuousClock.now + startDeadline
                while session.state != .started, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            guard session.state == .started else { throw MotionChannelFailure.sessionNotStarted }
            let added: Motion?
            do {
                added = try session.addMotion(configuration: WristMotionConfiguration.sdk)
            } catch {
                throw MotionChannelFailure.addFailed
            }
            guard let motion = added else { throw MotionChannelFailure.capabilityNotAdded }
            let channel = MetaMotionChannel(session: session, motion: motion, coordinator: coordinator,
                                            handlers: handlers)
            motion.start()
            return channel
        } catch {
            // Nothing was added, or what was is gone: hand the session back.
            coordinator.release(.motion)
            throw error
        }
    }

    // MARK: - The SDK's words in the app's

    nonisolated static func origin(_ source: MotionSource) -> WristSampleOrigin {
        switch source {
        case .glasses: return .glasses
        case .neuralBand: return .neuralBand
        case .unknown: return .unknown
        }
    }

    /// The sample's time, orientation and gyroscope. The accelerometer and magnetometer are not
    /// read. Qualified: the app has a `MotionSample` of its own (the parking drive detector's).
    nonisolated static func sample(_ sample: MWDATMotion.MotionSample) -> WristSample {
        WristSample(
            timestampNs: sample.timestampNs,
            orientation: sample.orientation.map {
                WristQuaternion(x: Double($0.x), y: Double($0.y), z: Double($0.z), w: Double($0.w))
            },
            gyroscope: sample.gyroscope.map { WristVector(x: Double($0.x), y: Double($0.y), z: Double($0.z)) })
    }

    /// Not frozen: a case added in a later SDK is `.unknown` until it is read and named here.
    nonisolated static func state(_ state: MotionState) -> MotionChannelState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .started: return .started
        case .stopping: return .stopping
        @unknown default: return .unknown
        }
    }

    /// Not frozen: a case added in a later SDK is `.unknown` until it is read and named here.
    nonisolated static func failure(_ error: MotionError) -> MotionChannelFailure {
        switch error {
        case .sensorUnavailable: return .sensorUnavailable
        case .capabilityClosed: return .capabilityClosed
        case .deviceDisconnected: return .deviceDisconnected
        @unknown default: return .unknown
        }
    }
}

/// The capability while it is held: its state and error listeners in a `ListenerTokenBag`
/// (attached straight after `addMotion`, before `start()`: neither publisher replays), its samples
/// and the session's state stream each read by a task, all ended together.
@MainActor
final class MetaMotionChannel: MotionChannel {
    private let session: DeviceSession
    private let motion: Motion
    private let coordinator: DeviceSessionCoordinator
    private let tokens = ListenerTokenBag()
    private var samplesTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var stopped = false

    init(session: DeviceSession, motion: Motion, coordinator: DeviceSessionCoordinator,
         handlers: MotionChannelHandlers) {
        self.session = session
        self.motion = motion
        self.coordinator = coordinator
        let onState = handlers.onState
        let onFailure = handlers.onFailure
        motion.statePublisher.listen { state in
            let mapped = MetaMotionSource.state(state)
            Task { @MainActor in onState(mapped) }
        }.store(in: tokens)
        motion.errorPublisher.listen { error in
            let mapped = MetaMotionSource.failure(error)
            Task { @MainActor in onFailure(mapped) }
        }.store(in: tokens)
        // 30 samples a second: each is mapped and handed on, nothing more, and never kept.
        let samples = motion.samples
        samplesTask = Task { @MainActor in
            for await sample in samples {
                let origin = MetaMotionSource.origin(sample.source)
                if origin == .neuralBand {
                    handlers.onSample(MetaMotionSource.sample(sample))
                } else {
                    handlers.onOtherSample(origin)
                }
            }
        }
        // The session's state stream finishes once it reaches `.stopped` (DAT 0.9.0).
        let states = session.stateStream()
        sessionTask = Task { @MainActor [weak self] in
            for await _ in states {}
            guard !Task.isCancelled, let self, !self.stopped else { return }
            handlers.onEnded()
        }
    }

    var state: MotionChannelState { MetaMotionSource.state(motion.state) }

    /// Stop, remove (which releases the sensors on the glasses), hand the session back.
    func stop() {
        guard !stopped else { return }
        stopped = true
        samplesTask?.cancel()
        sessionTask?.cancel()
        motion.stop()
        try? session.removeMotion()
        coordinator.release(.motion)
        let tokens = tokens
        Task { await tokens.cancelAll() }
    }
}
#endif
