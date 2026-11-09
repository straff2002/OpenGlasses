import Foundation

/// Whether Assisting is this phone's owner's, and what the Home screen says about it (Plan KW §2).
///
/// Assisting needs no Field Assist, so it can't live behind Field Assist's paywall, and it is
/// nothing to a phone that has never been asked to advise. It shows once it is the owner's: they
/// have a card, hold a handover, have time on their ledger, or have an invite open. Then the hub
/// draws its row (in Simple Mode too) and Home may carry one card.
///
/// Pure: it takes facts, never the stores, so the hub and Home can ask without naming them.
struct AssistingPresence: Equatable, Sendable {

    /// One held handover, as far as presence cares.
    struct HeldFact: Equatable, Sendable {
        let id: String
        let organisation: String
        /// Take this job was tapped.
        let taken: Bool
        let running: Bool
        let receivedAt: Date
        /// Swiped off the Home screen.
        let dismissed: Bool
    }

    /// One open invite.
    struct InviteFact: Equatable, Sendable {
        let id: String
        let organisation: String
        let receivedAt: Date
        let dismissed: Bool
    }

    /// The one Home card, in priority order: a clock running, then jobs not yet taken, then an
    /// invite. A card alone, a finished job or a ledger alone puts nothing on Home.
    enum HomeCard: Equatable, Sendable {
        /// A clock is running. With more than one, `count` says how many; `handoverId` is the
        /// newest. Never dismissed.
        case clock(handoverId: String, organisation: String, count: Int)
        /// Jobs sent and not yet taken, newest first. `organisation` is empty when they come from
        /// more than one.
        case newJobs(ids: [String], organisation: String)
        case invite(inviteId: String, organisation: String)

        /// The ids a swipe hides the card for. Empty when it can't be swiped away.
        var dismissalIds: [String] {
            switch self {
            case .clock: return []
            case .newJobs(let ids, _): return ids
            case .invite(let id, _): return [id]
            }
        }
    }

    let isPresent: Bool
    let homeCard: HomeCard?

    static let absent = AssistingPresence(isPresent: false, homeCard: nil)

    static func make(hasCard: Bool, held: [HeldFact], hasLedger: Bool, invites: [InviteFact]) -> AssistingPresence {
        let isPresent = hasCard || !held.isEmpty || hasLedger || !invites.isEmpty
        return AssistingPresence(isPresent: isPresent, homeCard: homeCard(held: held, invites: invites))
    }

    private static func homeCard(held: [HeldFact], invites: [InviteFact]) -> HomeCard? {
        let running = held.filter(\.running).sorted { $0.receivedAt > $1.receivedAt }
        if let newest = running.first {
            return .clock(handoverId: newest.id, organisation: newest.organisation, count: running.count)
        }
        let waiting = held.filter { !$0.taken && !$0.dismissed }.sorted { $0.receivedAt > $1.receivedAt }
        if let newest = waiting.first {
            let organisations = Set(waiting.map(\.organisation))
            return .newJobs(ids: waiting.map(\.id),
                            organisation: organisations.count == 1 ? newest.organisation : "")
        }
        if let invite = invites.filter({ !$0.dismissed }).max(by: { $0.receivedAt < $1.receivedAt }) {
            return .invite(inviteId: invite.id, organisation: invite.organisation)
        }
        return nil
    }
}

/// Things to Try's way in to the card before anyone asks (Plan KW §5). Kept outside
/// `ScenarioCatalog`, like `StreamLiveLink`: it is shown on every phone, a technician under a
/// profile included, because the expert's side belongs to no organisation. Once a card exists the
/// hub's Assisting row is the way in, so it goes.
enum ExpertCardLink {
    static func isVisible(hasCard: Bool) -> Bool { !hasCard }
}
