import Foundation

/// One hint in flight, and at most one waiting behind it (Plan MO §4, "One in flight").
///
/// A question that arrives while another is being answered does not start a second model call: it
/// waits, and a newer question replaces the one waiting, because by the time the first answer
/// lands the room has moved on to the newest question. When the answer in flight finishes, the
/// waiting question (if any) starts.
///
/// Pure; the session (P1) owns one and calls `offer` for each `.hint` the trigger returns.
struct HintQueue<Item: Equatable>: Equatable {

    /// What the queue says to do with an offered item.
    enum Offer: Equatable {
        /// Nothing was in flight: start this item now.
        case start(Item)
        /// Something is in flight: this item waits, replacing `replaced` if one was waiting.
        case waiting(replaced: Item?)
    }

    private(set) var inFlight: Item?
    private(set) var pending: Item?

    init() {}

    mutating func offer(_ item: Item) -> Offer {
        guard inFlight != nil else {
            inFlight = item
            return .start(item)
        }
        let replaced = pending
        pending = item
        return .waiting(replaced: replaced)
    }

    /// The item in flight is done (answered, failed or abandoned). Returns the waiting item, now in
    /// flight, to start; nil when nothing was waiting.
    mutating func finish() -> Item? {
        inFlight = pending
        pending = nil
        return inFlight
    }

    /// Forget everything (the session stopped).
    mutating func reset() {
        inFlight = nil
        pending = nil
    }
}
