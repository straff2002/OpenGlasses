import Foundation
import CoreMotion

/// Thin wrapper over `CMMotionActivityManager` that publishes whether the user is in active physical
/// motion — walking, running, cycling, or in a vehicle (Plan W v2). Feeds the presence
/// `motionActive` signal so a moving-but-quiet user isn't misread as idle (the plan's fast-follow
/// for noisy idle detection).
///
/// Device-only: `CMMotionActivityManager` is unavailable on the Simulator and needs the
/// `NSMotionUsageDescription` Info.plist key + the user's permission. When unavailable the provider
/// stays inert (`isActive == false`), so presence transparently falls back to its
/// voice/connectivity/foreground signals — no behaviour change where motion can't be read.
@MainActor
final class MotionActivityProvider: ObservableObject {
    @Published private(set) var isActive = false
    /// Every activity update as a pure sample (Plan GH) — parking capture reads the transitions,
    /// where presence only needs the boolean.
    var onSample: ((MotionSample) -> Void)?

    private let manager = CMMotionActivityManager()
    private var running = false

    /// Whether this device can report motion activity at all (false on Simulator / unsupported HW).
    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    /// Begin activity updates. No-op if unavailable or already running. Triggers the permission
    /// prompt on first use.
    func start() {
        guard Self.isAvailable, !running else { return }
        running = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            // CoreMotion delivers on the main OperationQueue; hop to the main actor to mutate state.
            let moving = MotionActivityProvider.isMoving(activity)
            let sample = activity.map(MotionActivityProvider.sample(from:))
            Task { @MainActor [weak self] in
                self?.isActive = moving
                if let sample { self?.onSample?(sample) }
            }
        }
    }

    /// Stop activity updates and clear the signal.
    func stop() {
        guard running else { return }
        running = false
        manager.stopActivityUpdates()
        isActive = false
    }

    /// Recorded activity between two instants, oldest first (Plan GH). CoreMotion keeps about a
    /// week of history, which is what lets a drive that ended while the app was suspended still be
    /// found when it next becomes active. Empty when unavailable or not permitted.
    func samples(from start: Date, to end: Date) async -> [MotionSample] {
        guard Self.isAvailable, start < end else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                continuation.resume(returning: (activities ?? []).map(MotionActivityProvider.sample(from:)))
            }
        }
    }

    /// `CMMotionActivity` → `MotionSample`. Automotive wins over the on-foot flags when both are
    /// set (a phone in a moving car can report both), and stationary is only reported when nothing
    /// else is.
    nonisolated static func sample(from activity: CMMotionActivity) -> MotionSample {
        let kind: MotionSample.Kind
        if activity.automotive { kind = .automotive }
        else if activity.running { kind = .running }
        else if activity.walking { kind = .walking }
        else if activity.cycling { kind = .cycling }
        else if activity.stationary { kind = .stationary }
        else { kind = .unknown }
        let confidence: MotionSample.Confidence
        switch activity.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        default: confidence = .low
        }
        return MotionSample(kind, confidence: confidence, at: activity.startDate)
    }

    /// Whether a `CMMotionActivity` represents active motion (vs stationary / unknown). Pulled out so
    /// the classification is a pure, inspectable function — `nonisolated` so callers (and tests) need
    /// no actor hop.
    nonisolated static func isMoving(_ activity: CMMotionActivity?) -> Bool {
        guard let activity else { return false }
        return activity.walking || activity.running || activity.cycling || activity.automotive
    }
}
