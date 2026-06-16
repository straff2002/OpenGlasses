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
            Task { @MainActor [weak self] in self?.isActive = moving }
        }
    }

    /// Stop activity updates and clear the signal.
    func stop() {
        guard running else { return }
        running = false
        manager.stopActivityUpdates()
        isActive = false
    }

    /// Whether a `CMMotionActivity` represents active motion (vs stationary / unknown). Pulled out so
    /// the classification is a pure, inspectable function — `nonisolated` so callers (and tests) need
    /// no actor hop.
    nonisolated static func isMoving(_ activity: CMMotionActivity?) -> Bool {
        guard let activity else { return false }
        return activity.walking || activity.running || activity.cycling || activity.automotive
    }
}
