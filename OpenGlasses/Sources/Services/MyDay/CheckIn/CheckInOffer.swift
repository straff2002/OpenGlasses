import Foundation

// Plan LE §6 (P2) — "Want to deal with the first one now?"
//
// The check-in asks only when the first item is a held approval whose call the router still keeps
// (`NativeToolRouter.canReplayHeld`), so a yes can actually put it back; after a relaunch the call is
// gone and nothing is offered. Asking leaves a **pending offer**: in memory only, single use, keyed to
// the held call's hold key, and gone after `lifetime`.
//
// **How the yes lands.** Not by intercepting the next utterance. The model hears the wearer's reply
// as an ordinary turn and, when it accepts the offer, calls `activity` with `deal_with_first`; that
// takes the offer (once) and runs `replayHeld` for its key. The replayed call goes through the whole
// ladder inside `HeldCallReplay.asksFirst`, so its own confirmation asks: nothing is approved by the
// check-in, the tool or the model. A `deal_with_first` with no live offer does nothing.
//
// The asked check-in ("what's waiting on me?") is already a model turn, so the offer is in the
// model's own reply. The scheduled one is spoken outside any turn, so while an offer is live each
// Direct-mode turn carries `turnNote` — content-free: it says an offer was made and how to take it,
// never what the item is. Live modes speak in the model's own session, which never hears the
// scheduled check-in, so there the scheduled check-in does not offer (`offersAfterScheduled`).

/// A spoken offer waiting for its answer.
struct CheckInOffer: Equatable, Sendable {
    /// The held call the offer is for (`ActivityHoldKey`).
    let holdKey: String
    /// The trail entry the call was held under.
    let entryID: UUID
    let madeAt: Date

    /// Long enough to say the wake word and "yes"; short enough that a later "yes" to something
    /// else is not taken for it.
    static let lifetime: TimeInterval = 5 * 60

    var expiresAt: Date { madeAt.addingTimeInterval(Self.lifetime) }

    func isLive(at now: Date) -> Bool {
        now >= madeAt && now < expiresAt
    }
}

enum CheckInOfferPolicy {

    /// The offer to make after `collection` is said, or nil: the first loop is an approval, its trail
    /// entry carries a hold key, and the router can still put that call back.
    static func offer(for collection: OpenLoopCollection, now: Date,
                      holdKey: (UUID) -> String?, canReplay: (String) -> Bool) -> CheckInOffer? {
        guard let first = collection.loops.first, first.source == .approval,
              case .approve(let entryID) = first.action,
              let key = holdKey(entryID), canReplay(key) else { return nil }
        return CheckInOffer(holdKey: key, entryID: entryID, madeAt: now)
    }

    /// What a `deal_with_first` finds.
    enum Take: Equatable {
        case replay(holdKey: String)
        case noOffer
        case expired
    }

    static func take(_ offer: CheckInOffer?, now: Date) -> Take {
        guard let offer else { return .noOffer }
        return offer.isLive(at: now) ? .replay(holdKey: offer.holdKey) : .expired
    }

    /// The model's note for a turn while an offer is live, or nil. Fixed words: never the item, the
    /// tool held or anyone's name.
    static func turnNote(_ offer: CheckInOffer?, now: Date) -> String? {
        guard let offer, offer.isLive(at: now) else { return nil }
        return """
        EVENING CHECK-IN OFFER: the evening check-in, spoken a moment ago, ended by asking the wearer \
        "Want to deal with the first one now?" (the first item is an action held for their OK). If the \
        wearer's reply accepts that offer, call the activity tool with action 'deal_with_first': it \
        puts the held action back in front of them through its own confirmation and approves nothing \
        itself. If they decline or talk about something else, do not call it.
        """
    }

    // MARK: Words

    static var nothingOffered: String {
        String(localized: "There's nothing I offered to deal with just now. It's all in My Day.",
               comment: "Spoken: the wearer said yes to dealing with the first check-in item, but no offer is waiting.")
    }

    static var cannotPutBack: String {
        String(localized: "I can't put that one back in front of you now. You can decline it in My Day.",
               comment: "Spoken: the held action the check-in offered can no longer be replayed (the app restarted or it lapsed).")
    }
}
