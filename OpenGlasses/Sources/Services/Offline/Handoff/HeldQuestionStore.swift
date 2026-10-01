import Foundation

/// The question the wearer asked when nothing on the phone could think it through (Plan GE P2).
///
/// One slot per conversation: a newer question replaces the held one, because the wearer has moved
/// on and answering the stale one first would be strange. Each question lives for ``ttl``
/// (30 minutes); on return a fresh one is answered by the cloud automatically and an expired one is
/// dropped with one line.
///
/// **In memory only, never persisted.** A held question is the wearer's own words; it exists to be
/// answered in a few minutes, not to be stored. A relaunch forgets it — that is the point.
struct HeldQuestionStore: Equatable {

    struct Held: Equatable {
        var question: String
        var heldAt: Date
    }

    enum HoldResult: Equatable {
        /// The slot was empty.
        case held
        /// A previous question in this conversation was replaced.
        case replaced
    }

    enum TakeResult: Equatable {
        case none
        /// Within its time-to-live: answer it.
        case fresh(String)
        /// Past its time-to-live: say so in one line and drop it.
        case expired
    }

    /// How long a held question is worth answering.
    let ttl: TimeInterval
    private(set) var slots: [String: Held] = [:]

    init(ttl: TimeInterval = 30 * 60) {
        self.ttl = ttl
    }

    /// Hold `question` for `conversationId`, replacing any question already held there.
    @discardableResult
    mutating func hold(_ question: String, conversationId: String, now: Date) -> HoldResult {
        let replaced = slots[conversationId] != nil
        slots[conversationId] = Held(question: question, heldAt: now)
        return replaced ? .replaced : .held
    }

    /// Remove and return the conversation's held question, classified by age.
    mutating func take(conversationId: String, now: Date) -> TakeResult {
        guard let held = slots.removeValue(forKey: conversationId) else { return .none }
        return isExpired(held, now: now) ? .expired : .fresh(held.question)
    }

    /// Drop every question past its time-to-live and return how many went. Called on the probe tick
    /// so an expiry can be offered as a notification while still offline.
    mutating func expire(now: Date) -> Int {
        let expired = slots.filter { isExpired($0.value, now: now) }.map(\.key)
        expired.forEach { slots.removeValue(forKey: $0) }
        return expired.count
    }

    /// Forget everything (a conversation reset, or the feature turned off).
    mutating func removeAll() { slots.removeAll() }

    var isEmpty: Bool { slots.isEmpty }

    func isHolding(conversationId: String) -> Bool { slots[conversationId] != nil }

    private func isExpired(_ held: Held, now: Date) -> Bool {
        now.timeIntervalSince(held.heldAt) >= ttl
    }
}
