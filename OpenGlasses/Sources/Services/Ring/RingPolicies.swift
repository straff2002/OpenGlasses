import Foundation

// The ring service's decisions, as pure values (Plan MZ §7): when to reconnect, how often to sync,
// when a live session may start by itself, and when the ring's battery is mentioned.

/// When to try the link again after it drops (Plan MZ decision 3). The connect is a pending one,
/// which iOS completes whenever the ring comes back in range, so the backoff only spaces out
/// retries after a refused or failed connect; it never gives up while the app runs.
enum RingReconnectPolicy {

    static let delays: [TimeInterval] = [2, 5, 15, 30, 60]

    /// The wait before attempt `failures + 1`, where `failures` counts drops since the link was
    /// last ready.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        delays[min(max(failures, 0), delays.count - 1)]
    }
}

/// How power posture shapes the ring's work (Plan MZ §7 Power).
enum RingPowerPolicy {

    /// How often a linked ring is synced while the app runs.
    static let baseSyncInterval: TimeInterval = 30 * 60

    /// Conserve doubles the periodic sync; the ring's own heart-rate schedule is left as the
    /// wearer set it.
    static func syncInterval(_ posture: PowerPosture) -> TimeInterval {
        posture >= .conserve ? baseSyncInterval * 2 : baseSyncInterval
    }

    /// A live heart-rate session the wearer did not just ask for (a workout's session restarted
    /// after the link came back) does not start at reserve.
    static func mayStartLiveSession(requestedNow: Bool, posture: PowerPosture) -> Bool {
        requestedNow || posture != .reserve
    }
}

/// The ring's battery at 10 %, said once per charge. Pure.
struct RingBatteryNotice: Equatable, Sendable {

    static let lowPercent = 10
    /// Above this the ring has been charged, and the next low battery is said again.
    static let rearmPercent = 20

    private(set) var armed = true

    /// Whether this reading is the one to mention.
    mutating func shouldAnnounce(percent: Int) -> Bool {
        if percent >= Self.rearmPercent {
            armed = true
            return false
        }
        guard armed, percent <= Self.lowPercent else { return false }
        armed = false
        return true
    }

    static var line: String {
        String(localized: "Your ring's battery is low. Charge it soon.")
    }
}

/// The note that the ring's own app still holds the ring (Plan MZ decision 9): shown once, when a
/// ring is found through another app's connection, until the ring is forgotten.
enum RingOtherAppNotice {

    static func shouldShow(for candidate: RingCandidate, alreadyShown: Bool) -> Bool {
        candidate.heldByAnotherApp && !alreadyShown
    }

    static var text: String {
        String(localized: "The ring's own app is still connected to it and may change its clock and heart-rate schedule. Remove that app from this iPhone so only Avenkin talks to the ring.")
    }
}
