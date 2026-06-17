import Foundation
import CoreMotion

/// Owns the opt-in alternative triggers (Additional Capabilities #5) and routes every detected event
/// through a `TriggerGate` (confidence + debounce + suppression) to a single `onTrigger` callback,
/// which `AppState` wires to the same entry point as the wake word.
///
/// The **gating + routing** is the tested architectural value: detectors are noisy, so they all funnel
/// through `handleEvent`, which is pure enough to drive headlessly with an injected clock and synthetic
/// events. The **detectors** themselves are device-runtime — the CoreMotion shake detector is wired
/// live; the acoustic (`SoundAnalysis`) and volume-button (`AVAudioSession` KVO) detectors are deferred
/// (they need on-device tuning + battery/mic coordination with the wake-word pipeline and the
/// Presence-Aware Throttle).
@MainActor
final class AlternativeTriggerService {

    /// Fired when a gated trigger passes. `AppState` routes this to `handleWakeWordDetected`.
    var onTrigger: ((AlternativeTrigger) -> Void)?

    /// Whether triggers are currently suppressed (a conversation / critical card is held). Mirrors the
    /// wake-word guard. `AppState` supplies it; defaults to never-suppressed.
    var isSuppressed: () -> Bool = { false }

    private var gates: [AlternativeTrigger: TriggerGate]
    private let clock: () -> TimeInterval
    private let isEnabled: (AlternativeTrigger) -> Bool

    /// userAcceleration magnitude (g, gravity excluded) that counts as a deliberate shake.
    static let shakeThreshold: Double = 2.2

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private(set) var isRunning = false

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         isEnabled: @escaping (AlternativeTrigger) -> Bool = { Config.alternativeTriggerEnabled($0) },
         debounceInterval: TimeInterval = 2.0,
         minimumConfidence: Double = 0.6) {
        self.clock = clock
        self.isEnabled = isEnabled
        self.gates = Dictionary(uniqueKeysWithValues: AlternativeTrigger.allCases.map {
            ($0, TriggerGate(debounceInterval: debounceInterval, minimumConfidence: minimumConfidence))
        })
    }

    // MARK: - Routing (tested)

    /// Feed a raw detected event. Fires `onTrigger` iff the trigger is enabled **and** the gate passes
    /// (confidence ≥ threshold, outside the debounce window, not suppressed). Returns whether it fired.
    @discardableResult
    func handleEvent(_ trigger: AlternativeTrigger, confidence: Double = 1.0) -> Bool {
        guard isEnabled(trigger) else { return false }
        let suppressed = isSuppressed()
        guard gates[trigger]?.shouldFire(at: clock(), confidence: confidence, suppressed: suppressed) == true else {
            return false
        }
        onTrigger?(trigger)
        return true
    }

    // MARK: - Lifecycle

    /// Start the detectors for the enabled triggers. Idempotent. Currently wires the CoreMotion shake
    /// detector; acoustic + volume detectors are deferred (see the type doc).
    func start() {
        guard !isRunning else { return }
        guard AlternativeTrigger.allCases.contains(where: isEnabled) else { return }
        isRunning = true
        startShakeDetectorIfEnabled()
    }

    /// Stop all detectors.
    func stop() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
    }

    /// Re-evaluate which detectors should run (call when the user toggles a trigger in Settings).
    func refresh() {
        stop()
        start()
    }

    // MARK: - Shake detector (device runtime)

    private func startShakeDetectorIfEnabled() {
        guard isEnabled(.shake), motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.05
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion else { return }
            let a = motion.userAcceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            guard magnitude > AlternativeTriggerService.shakeThreshold else { return }
            Task { @MainActor in self?.handleEvent(.shake) }
        }
    }
}
