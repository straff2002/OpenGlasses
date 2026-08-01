import Foundation
import UIKit

/// Plan CE — Frame Pinning: freeze what the model sees so "this" stays stable while the
/// wearer's head (and therefore the camera) keeps moving.
///
/// A pin gates **only the model-facing frame path** — the push chokepoint, the poll fallbacks,
/// and Direct-mode photo reuse, all in AppState wiring. Every other `framePublisher` consumer
/// (recording, broadcast, face recognition, reading, expert streams) keeps receiving live
/// frames; that's why the gate lives at the chokepoints and not inside `CameraService`.

// MARK: - Pin state

/// The pinned frame — single source of truth, owned by AppState. UI observes it for the
/// pinned-card overlay; the gate and the photo paths read it.
@MainActor
final class FramePin: ObservableObject {
    @Published private(set) var pinnedFrame: UIImage?
    @Published private(set) var pinnedAt: Date?

    var isPinned: Bool { pinnedFrame != nil }

    func pin(frame: UIImage, at date: Date = Date()) {
        pinnedFrame = frame
        pinnedAt = date
    }

    /// Returns true when a pin was actually held (callers skip gate resets on a no-op).
    @discardableResult
    func unpin() -> Bool {
        guard pinnedFrame != nil else { return false }
        pinnedFrame = nil
        pinnedAt = nil
        return true
    }
}

// MARK: - Delivery gate

/// Pure per-frame policy at the push chokepoint. Not pinned → live frames flow untouched.
/// Pinned → live frames are suppressed, except a heartbeat re-send of the *pinned* frame so a
/// long-lived realtime session doesn't treat the feed as dead (cadence mirrors `FrameGate`'s
/// heartbeat). The first decision after a pin is `.resendPinned` — but the wiring pushes the
/// pinned frame immediately on pin (sharp-inject, bypassing the throttler) and records it via
/// `notePinnedPushed`, so the model's referent is the on-screen frame the instant it's taken.
struct FramePinGate {

    enum Decision: Equatable {
        /// Not pinned — the live frame goes through the normal throttled path.
        case deliverLive
        /// Pinned and the model already has the pinned frame — drop the live frame.
        case suppress
        /// Pinned and the heartbeat elapsed (or nothing sent yet) — push the pinned frame.
        case resendPinned
    }

    /// Seconds between pinned-frame re-sends. Mirrors `FrameGate`'s default heartbeat.
    let heartbeat: TimeInterval

    private var lastPinnedSend: TimeInterval?

    init(heartbeat: TimeInterval = 12) {
        self.heartbeat = max(0, heartbeat)
    }

    mutating func evaluate(isPinned: Bool, now: TimeInterval) -> Decision {
        guard isPinned else {
            lastPinnedSend = nil
            return .deliverLive
        }
        guard let last = lastPinnedSend else {
            lastPinnedSend = now
            return .resendPinned
        }
        if heartbeat > 0, now - last >= heartbeat {
            lastPinnedSend = now
            return .resendPinned
        }
        return .suppress
    }

    /// The pinned frame was pushed outside the evaluate loop (the immediate sharp-inject on
    /// pin) — start the heartbeat clock from that push.
    mutating func notePinnedPushed(now: TimeInterval) {
        lastPinnedSend = now
    }

    mutating func reset() {
        lastPinnedSend = nil
    }
}

// MARK: - Release policy

/// Everything that ends a pin. A pin is an explicit act, so the only *automatic* release
/// beyond lifecycle teardown is the optional max-age expiry (default off).
enum FramePinReleaseTrigger: CaseIterable {
    case explicitUnpin      // tap the card, voice "unpin", tool call
    case sessionStop        // the live session the pin was feeding ended
    case modeSwitch         // switching brains — CF's redial re-pushes instead (open q resolved)
    case cameraTeardown     // no camera → the pin's provenance is gone
    case expired            // optional max-age auto-expiry
}

enum FramePinReleasePolicy {
    /// All lifecycle triggers release. Kept as an explicit set (not `return true`) so a future
    /// trigger must decide its behavior consciously — the test walks `allCases`.
    static let releasingTriggers: Set<FramePinReleaseTrigger> = [
        .explicitUnpin, .sessionStop, .modeSwitch, .cameraTeardown, .expired,
    ]

    static func shouldRelease(on trigger: FramePinReleaseTrigger) -> Bool {
        releasingTriggers.contains(trigger)
    }

    /// `maxAge` nil (the default) means a pin never expires on its own.
    static func isExpired(pinnedAt: Date, now: Date, maxAge: TimeInterval?) -> Bool {
        guard let maxAge else { return false }
        return now.timeIntervalSince(pinnedAt) >= maxAge
    }
}

// MARK: - Config

extension Config {
    /// Kill switch for the whole feature (default on — inert until a pin is taken).
    static var framePinEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "framePinEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "framePinEnabled") }
    }
}
