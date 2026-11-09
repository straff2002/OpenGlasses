import Foundation

/// An invite this phone sent asking an expert for their card (Plan KW §4), shown on the experts
/// list as invited until a card answers it or it runs out. Only what the list needs: the id the
/// answering card carries, the name typed for the list, and the dates. Kept in `ExpertListStore`.
struct SentExpertInvite: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The name typed for the list; may be empty.
    let inviteeName: String
    let sentAt: Date
    let expires: Date

    init(invite: ExpertInvite, inviteeName: String) {
        self.id = invite.inviteId
        self.inviteeName = ExpertInvite.cleaned(inviteeName, max: ExpertInvite.maxNameLength)
        self.sentAt = invite.created
        self.expires = invite.expires
    }

    func isOpen(at now: Date) -> Bool { now < expires }

    /// Most first: at most this many are kept.
    static let cap = 50

    /// The invites still open, newest first, capped.
    static func kept(_ invites: [SentExpertInvite], at now: Date) -> [SentExpertInvite] {
        Array(invites.filter { $0.isOpen(at: now) }.sorted { $0.sentAt > $1.sentAt }.prefix(cap))
    }
}
