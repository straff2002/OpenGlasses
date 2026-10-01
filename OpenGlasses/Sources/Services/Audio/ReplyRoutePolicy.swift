import Foundation

/// Plan GU §4 — the "Reply audio" setting.
enum ReplyAudioMode: String, CaseIterable, Identifiable, Sendable {
    /// The conversation mic stays open through the reply, so barge-in and the stop phrase always
    /// work. Replies play over the call link. The default.
    case callQuality
    /// Replies play in full quality (A2DP) every time; interrupting uses the phone mic.
    case fullQuality
    /// Full quality only when this pair of glasses switches fast enough.
    case automatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .callQuality: return "Call quality, always interruptible"
        case .fullQuality: return "Full quality"
        case .automatic: return "Automatic"
        }
    }

    var shortLabel: String {
        switch self {
        case .callQuality: return "Call quality"
        case .fullQuality: return "Full quality"
        case .automatic: return "Automatic"
        }
    }
}

/// How one reply is played.
enum ReplyRoute: Equatable {
    /// Keep the hands-free link the conversation opened. One switch in, one hand-back out.
    case holdCallLink
    /// Release the hands-free link before the reply; play it on A2DP; listen for a barge-in on the
    /// phone mic; take the link again only when a follow-up starts.
    case fullQuality
}

/// Decides `ReplyRoute` for a reply. Pure.
enum ReplyRoutePolicy {

    /// "Switch time limit" bounds and default, in seconds.
    static let thresholdRange: ClosedRange<Double> = 0.3...2.0
    static let defaultThreshold: Double = 0.7

    static func clampedThreshold(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultThreshold }
        return min(max(seconds, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    struct Inputs: Equatable {
        var mode: ReplyAudioMode
        /// The rolling median switch time for the device the conversation is on, if measured.
        var measuredSwitchSeconds: Double?
        var thresholdSeconds: Double = ReplyRoutePolicy.defaultThreshold
        /// The mic the conversation is actually on.
        var conversationRoute: MicRoute
        /// Display glasses: the call screen and the HUD already contend, and a reply that flips
        /// the link twice per follow-up would flash it — held on the call link.
        var displayGlasses: Bool = false
        /// A realtime session owns its own audio.
        var realtime: Bool = false
        var carPlay: Bool = false
    }

    static func decide(_ inputs: Inputs) -> ReplyRoute {
        // Nothing to release on the phone, and the exclusions keep their own audio.
        guard inputs.conversationRoute != .phone,
              !inputs.displayGlasses, !inputs.realtime, !inputs.carPlay else { return .holdCallLink }
        switch inputs.mode {
        case .callQuality:
            return .holdCallLink
        case .fullQuality:
            return .fullQuality
        case .automatic:
            // Unmeasured is not fast: until this pair has switched at least once, keep the link.
            guard let measured = inputs.measuredSwitchSeconds else { return .holdCallLink }
            return measured < clampedThreshold(inputs.thresholdSeconds) ? .fullQuality : .holdCallLink
        }
    }
}

/// Plan GU §4 — measured mic switch times, a rolling median per device, persisted.
///
/// A device key is an opaque hash of the port's UID — never its name, which is the wearer's own
/// ("Greig's Ray-Ban Meta"). Values are seconds from asking for the conversation mic to its first
/// live buffers (`turnMicLive`).
struct SwitchTimeLedger: Codable, Equatable {
    /// How many recent switches the median is taken over.
    static let window = 7

    private(set) var samples: [String: [Double]] = [:]

    mutating func record(_ seconds: Double, device: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var list = samples[device] ?? []
        list.append(seconds)
        if list.count > Self.window { list.removeFirst(list.count - Self.window) }
        samples[device] = list
    }

    func median(device: String) -> Double? {
        guard let list = samples[device], !list.isEmpty else { return nil }
        let sorted = list.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// A stable, non-reversible key for a port UID (FNV-1a, 64-bit, hex).
    static func deviceKey(portUID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in portUID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
