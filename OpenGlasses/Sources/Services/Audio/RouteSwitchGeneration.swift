import AVFoundation

/// Plan GU §3 — the app's own route switches, so the route-change handler can tell them from a
/// disruption.
///
/// Every switch the app makes (idle → conversation, the hand-back, the idle re-arm) changes the
/// category and often the route, and iOS reports each as a route change — asynchronously, after
/// the call that caused it has returned. Without this, `.oldDeviceUnavailable` from our own move
/// off the hands-free link paused the brand-new idle listener as a "disconnect". A switch is open
/// from `begin` until `settleSeconds` after `end`, to cover the notifications' lag.
///
/// Pure: times are passed in.
struct RouteSwitchGeneration: Equatable {
    /// How long after a switch ends its route-change notifications are still treated as ours.
    static let settleSeconds: TimeInterval = 1.0

    private(set) var generation: UInt64 = 0
    private var inFlight: Set<UInt64> = []
    private var settleUntil: Date?

    /// A switch is starting. Returns its generation, to hand back to `end`.
    mutating func begin() -> UInt64 {
        generation &+= 1
        inFlight.insert(generation)
        return generation
    }

    /// The switch's own calls have returned; its notifications may still be on the way.
    mutating func end(_ generation: UInt64, at now: Date) {
        inFlight.remove(generation)
        let until = now.addingTimeInterval(Self.settleSeconds)
        if let current = settleUntil, current > until { return }
        settleUntil = until
    }

    /// Whether a route change observed now belongs to one of our switches.
    func isOwnSwitch(at now: Date) -> Bool {
        if !inFlight.isEmpty { return true }
        guard let settleUntil else { return false }
        return now < settleUntil
    }
}

/// Whether a route change is the app's own doing or a disruption to react to.
enum SelfRouteChangeFilter {
    enum Verdict: Equatable { case ignore, handle }

    /// The reasons our own switches produce. `.newDeviceAvailable` is not among them — a device
    /// arriving is never something we caused.
    static let ownSwitchReasons: Set<UInt> = [
        AVAudioSession.RouteChangeReason.categoryChange.rawValue,
        AVAudioSession.RouteChangeReason.override.rawValue,
        AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
    ]

    /// - Parameter bluetoothLost: neither a Bluetooth mic nor a Bluetooth output remains in the
    ///   route. A device that really went away during one of our switches is still a disconnect.
    static func verdict(reason: AVAudioSession.RouteChangeReason, ownSwitchInFlight: Bool,
                        bluetoothLost: Bool) -> Verdict {
        guard ownSwitchInFlight, ownSwitchReasons.contains(reason.rawValue) else { return .handle }
        if reason == .oldDeviceUnavailable && bluetoothLost { return .handle }
        return .ignore
    }
}
