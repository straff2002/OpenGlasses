import Foundation

/// The stale-frame rule for answer-card page turns and actions (Plan KP §2, from Plan IB).
///
/// `GlassesDisplayService` bumps a frame revision on every render it enqueues (an ambient op, a
/// screen, a clear, a page). A page turn or a card action carries the revision it was issued
/// against. When the render queue reaches it, the turn is drawn only if nothing has rendered in
/// between; otherwise it is dropped (and logged as stale), so a notification that arrived between
/// "next" and the page render wins and the card is abandoned rather than drawn over it.
enum PageTurnGate {
    static func accept(turnRevision: UInt64, currentRevision: UInt64) -> Bool {
        turnRevision == currentRevision
    }
}
