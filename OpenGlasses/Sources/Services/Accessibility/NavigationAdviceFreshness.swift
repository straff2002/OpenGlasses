import Foundation

/// Whether a navigation hazard callout is still about where the wearer is.
///
/// The navigation loop captures a frame, waits for the model, then speaks. A slow reply about a
/// kerb arrives after the wearer has walked past it, and for a blind wearer advice about where
/// they were is worse than none. So the age of the *frame* is checked at speak time, and advice
/// older than `Config.navigationAdviceMaxAge` is dropped. Urgency buys no exemption: a stale
/// "vehicle, ten o'clock" is just as wrong as a stale "door ahead".
///
/// Pure and deterministic — times are seconds on one monotonic clock (`CACurrentMediaTime()` in
/// the app, a fake in tests). An age exactly at the limit is still fresh. An age that cannot be
/// right (negative, or not finite) fails closed: silence is the safe answer when the clock itself
/// cannot be trusted.
enum NavigationAdviceFreshness {

    static func age(capturedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        now - capturedAt
    }

    static func isFresh(capturedAt: TimeInterval, now: TimeInterval,
                        maxAge: TimeInterval = Config.navigationAdviceMaxAge) -> Bool {
        let age = age(capturedAt: capturedAt, now: now)
        guard age.isFinite, maxAge.isFinite else { return false }
        return age >= 0 && age <= maxAge
    }
}
