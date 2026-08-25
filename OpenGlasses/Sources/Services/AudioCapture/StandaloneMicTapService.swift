import AVFoundation
import Foundation

/// A mic source that can be started and stopped on demand, on top of the buffer-consumer seam the
/// capture consumers already use. Injected into `CaptureAudioRouter` so tests can drive a fake.
@MainActor
protocol CaptureAudioEngineProviding: BroadcastAudioProviding {
    var isRunning: Bool { get }
    func start() async throws
    func stop()
}

enum StandaloneMicTapError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat(sampleRate: Double, channels: UInt32)
    case engineDidNotStart

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .invalidInputFormat(let sampleRate, let channels):
            return "Audio input format invalid (\(Int(sampleRate))Hz, \(channels)ch)"
        case .engineDidNotStart:
            return "Capture audio engine did not start"
        }
    }
}

/// A self-contained microphone capture engine for streams and recordings.
///
/// This exists for one gap: capture audio has always come from the always-on listener's input tap,
/// and that tap only exists while listening is on. Turning listening off mid-stream — a reasonable
/// thing to do — silently produced video-only output. This engine covers that gap and nothing else;
/// it is started by `CaptureAudioRouter` only while capture is live and the shared tap is down, and
/// stopped the moment either of those stops being true.
///
/// It deliberately mirrors the shared tap's discipline rather than inventing its own:
///  - the input format is validated before the tap is installed (a Bluetooth route that has gone
///    away reports 0 Hz / 0 channels, and installing a tap with that format crashes),
///  - the buffer size is the same 1024,
///  - and the tap block touches nothing but the lock-guarded fan-out box — no `@MainActor` state is
///    read from the render thread.
///
/// Session ownership goes through the shared coordinator, so starting here supersedes cleanly and
/// stopping deactivates *only* if nothing newer has taken the session in the meantime.
@MainActor
final class StandaloneMicTapService: ObservableObject, CaptureAudioEngineProviding {
    @Published private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var sessionLease: AudioSessionLease?
    private var consumers: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let fanout = CaptureAudioFanout()

    // MARK: - Lifecycle

    func start() async throws {
        if let engine, engine.isRunning {
            isRunning = true
            return
        }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw StandaloneMicTapError.microphonePermissionDenied
        }

        // Nothing else has configured the session when the shared tap is down, so we configure it
        // ourselves — with the same category/options the always-on listener uses, so a later
        // handover back to it does not re-tune the route underneath the capture.
        let options = MicRoutePolicy.categoryOptions(for: Config.micRoute, mixWithOthers: true)
        do {
            sessionLease = try await AudioSessionCoordinator.shared.acquireOffMain(
                .captureAudio, category: .playAndRecord, mode: .default, options: options)
        } catch {
            NSLog("[CaptureAudio] Session acquire failed: %@", error.localizedDescription)
            throw error
        }
        preferConfiguredMicIfAvailable(AVAudioSession.sharedInstance())

        do {
            try createAndStartEngine()
        } catch {
            releaseSession()
            throw error
        }
        isRunning = true
        NSLog("[CaptureAudio] Standalone mic tap started")
    }

    func stop() {
        guard engine != nil || isRunning else { return }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        isRunning = false
        releaseSession()
        NSLog("[CaptureAudio] Standalone mic tap stopped")
    }

    // MARK: - Consumers

    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        consumers[id] = handler
        fanout.setConsumers(Array(consumers.values))
    }

    func removeAudioBufferConsumer(id: String) {
        consumers.removeValue(forKey: id)
        fanout.setConsumers(Array(consumers.values))
    }

    // MARK: - Engine

    private func createAndStartEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Validate before installing — a stale/absent Bluetooth route reports a zero format and
        // installing a tap with it crashes rather than failing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[CaptureAudio] Input format invalid (%.0fHz, %uch) — cannot start",
                  format.sampleRate, format.channelCount)
            throw StandaloneMicTapError.invalidInputFormat(
                sampleRate: format.sampleRate, channels: format.channelCount)
        }

        // The tap runs on the Core Audio render thread: it must touch nothing but the lock-guarded
        // box (same rule as the shared tap).
        let fanout = self.fanout
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            fanout.dispatch(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        guard engine.isRunning else {
            inputNode.removeTap(onBus: 0)
            throw StandaloneMicTapError.engineDidNotStart
        }
        self.engine = engine
        NSLog("[CaptureAudio] Engine running: %.0fHz, %uch", format.sampleRate, format.channelCount)
    }

    /// Release our session claim. The coordinator deactivates only if we are still the current
    /// owner, so a live session that took the mic while we were capturing is left alone.
    private func releaseSession() {
        guard let lease = sessionLease else { return }
        sessionLease = nil
        AudioSessionCoordinator.shared.release(lease)
    }

    /// Prefer the configured mic route's input if it is present — the same selection the always-on
    /// listener makes, so the capture doesn't quietly come up on the phone mic when the glasses are
    /// the configured source.
    private func preferConfiguredMicIfAvailable(_ session: AVAudioSession) {
        let route = Config.micRoute
        guard route != .phone, let inputs = session.availableInputs else { return }
        let ports = inputs.map { (name: $0.portName, type: $0.portType) }
        guard let index = MicRoutePolicy.preferredInputIndex(for: route, ports: ports) else { return }
        do {
            try session.setPreferredInput(inputs[index])
        } catch {
            NSLog("[CaptureAudio] Could not prefer %@ mic: %@", route.rawValue, error.localizedDescription)
        }
    }
}
