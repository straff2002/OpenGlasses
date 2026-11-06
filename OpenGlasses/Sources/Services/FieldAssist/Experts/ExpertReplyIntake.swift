import Foundation
import Combine

/// An expert's time reply, as the technician's job keeps it (Plan KM P2): what the expert's app
/// said, matched to the handover this phone sent. Reconciliation against the call the phone saw
/// is Plan KM P4; this keeps the reply as it arrived.
struct ExpertReplyReceived: Codable, Equatable, Sendable {
    enum MatchedBy: String, Codable, Sendable {
        /// The list entry was made from the expert's card, and the reply carries the same card.
        case card
        /// The list entry was typed or picked from Contacts; the reply answers it by its id.
        case listEntry
    }

    let handoverId: String
    /// The expert as the job's own sent record has them — never a name the reply chose.
    let expert: ExpertSnapshot
    let generationsSeen: [Int]
    let acceptedAt: Date
    let doneAt: Date
    let minutes: Int
    let uncountedMinutes: Int
    let callMinutes: Int?
    let note: String?
    let matchedBy: MatchedBy
    let receivedAt: Date
}

/// Whether a reply answers a handover this phone sent (Plan KM §5, P2). Pure.
///
/// **Accepted only when** the handover id is one of this phone's sent records, the reply is
/// addressed to the expert that handover went to, an entry made from a card is answered by that
/// same card, and every generation it claims was one this phone sent. Anything else is refused by
/// name and never attached: a reply is a file anyone could write.
enum ExpertReplyMatch {

    enum Refusal: Error, Equatable {
        /// No job on this phone sent that handover.
        case unknownHandover
        /// The handover went to another expert.
        case otherSender
        /// The expert was listed from a card, and the reply does not carry that card.
        case cardMismatch
        /// It claims to have seen an update this phone never sent.
        case generationNotSent

        var message: String {
            switch self {
            case .unknownHandover:
                return "That reply doesn't answer a handover this phone sent, so it wasn't loaded."
            case .otherSender, .cardMismatch:
                return "That reply isn't from the expert the handover went to, so it wasn't loaded."
            case .generationNotSent:
                return "That reply mentions an update this phone never sent, so it wasn't loaded."
            }
        }
    }

    struct Match: Equatable {
        let sessionId: String
        let received: ExpertReplyReceived
    }

    /// - Parameter sessions: the jobs this phone holds — the open one and the history.
    static func match(_ reply: ExpertTimeReply, sessions: [FieldSession], now: Date) -> Result<Match, Refusal> {
        guard let session = sessions.first(where: { ($0.expertHandovers ?? []).contains { $0.handoverId == reply.handoverId } }),
              let sent = session.expertHandovers?.filter({ $0.handoverId == reply.handoverId }),
              let first = sent.first else {
            return .failure(.unknownHandover)
        }
        let expert = first.expert
        guard sent.allSatisfy({ $0.expert.id == expert.id }), reply.expert.listId == expert.id else {
            return .failure(.otherSender)
        }
        let fromCard = ExpertCard.isCardId(expert.id)
        if fromCard, reply.expert.cardId != expert.id { return .failure(.cardMismatch) }
        let sentGenerations = Set(sent.map(\.generation))
        guard !reply.generationsSeen.isEmpty, Set(reply.generationsSeen).isSubset(of: sentGenerations) else {
            return .failure(.generationNotSent)
        }
        let received = ExpertReplyReceived(
            handoverId: reply.handoverId, expert: expert,
            generationsSeen: Array(Set(reply.generationsSeen)).sorted(),
            acceptedAt: reply.acceptedAt, doneAt: reply.doneAt,
            minutes: max(0, reply.minutes), uncountedMinutes: max(0, reply.uncountedMinutes),
            callMinutes: reply.callMinutes.map { max(0, $0) },
            note: ExpertTimeReply.cleanedNote(reply.note),
            matchedBy: fromCard ? .card : .listEntry, receivedAt: now)
        return .success(Match(sessionId: session.id, received: received))
    }

    /// The same reply twice is one reply.
    static func isDuplicate(_ received: ExpertReplyReceived, of held: [ExpertReplyReceived]) -> Bool {
        held.contains { $0.handoverId == received.handoverId && $0.doneAt == received.doneAt
            && $0.minutes == received.minutes && $0.generationsSeen == received.generationsSeen }
    }

    /// What the technician is told when it is attached.
    static func confirmation(_ received: ExpertReplyReceived, jobReference: String?) -> String {
        let job = jobReference.map { "job \($0)" } ?? "the job"
        let minutes = received.minutes == 1 ? "1 minute" : "\(received.minutes) minutes"
        return "\(received.expert.name)'s time on \(job) is on the job: \(minutes)."
    }
}

/// Opens an expert's reply on the technician's phone (Plan KM P2) and attaches it to the job that
/// sent the handover, when — and only when — it answers one.
@MainActor
final class ExpertReplyIntake {
    static let shared = ExpertReplyIntake()

    var sessions: FieldSessionService = .shared
    var now: () -> Date = Date.init

    init() {}

    /// Attach the reply, or say why not. Returns what to tell the technician.
    func receive(_ reply: ExpertTimeReply) -> String {
        let held = (sessions.activeSession.map { [$0] } ?? []) + sessions.history
        switch ExpertReplyMatch.match(reply, sessions: held, now: now()) {
        case .failure(let refusal):
            PrivacyLog.transfer(.fieldSessionExport, .quarantined)
            return refusal.message
        case .success(let match):
            let reference = held.first { $0.id == match.sessionId }?.jobReference
            guard sessions.recordExpertReply(match.received, sessionId: match.sessionId) else {
                return "That reply is for a job this phone can no longer change, so it wasn't attached."
            }
            PrivacyLog.transfer(.fieldSessionExport, .imported, count: 1)
            return ExpertReplyMatch.confirmation(match.received, jobReference: reference)
        }
    }
}

// MARK: - Importing an expert's card (the organisation's side)

/// An expert card imported into the organisation's list (Plan KM §1, P2). Pure.
///
/// The card fills what it carries — name, number, FaceTime handle, the channel and the
/// specialties — under the card's own id, so a handover is addressed to it and the reply matches
/// it exactly. **The organisation adds the rest**: its own kind, on-call hours and, for a
/// contracted expert, the rate. The card carries none of them, so an import is always a `staff`
/// entry with no rate until the organisation says otherwise. With a profile in force the
/// organisation's list is the profile's, so the card becomes the technician's own addition.
enum ExpertCardImport {

    enum Destination: Equatable {
        /// The device owner's list (no profile): kind, hours and rate are set on the entry after.
        case organisation
        /// The technician's own additions (a profile owns the organisation's list).
        case personal
    }

    static func destination(organisationListIsManaged: Bool) -> Destination {
        organisationListIsManaged ? .personal : .organisation
    }

    /// The device owner's entry for a card: staff, no rate, on call any time, in this phone's zone.
    static func ownerEntry(_ card: ExpertCard, timeZoneIdentifier: String? = TimeZone.current.identifier) -> EscalationContact {
        EscalationContact(id: card.cardId, name: card.name, phone: card.phone, faceTimeHandle: card.faceTimeHandle,
                          handoverChannel: card.handoverChannel, specialties: card.specialties, kind: .staff,
                          timeZoneIdentifier: timeZoneIdentifier)
    }

    static func personalEntry(_ card: ExpertCard) -> PersonalExpert {
        PersonalExpert(id: card.cardId, name: card.name, phone: card.phone, faceTimeHandle: card.faceTimeHandle,
                       handoverChannel: card.handoverChannel, specialties: card.specialties)
    }

    enum Outcome: Equatable {
        case added(Destination)
        /// The same card was already listed: its details are refreshed, and the organisation's own
        /// kind, hours and rate are kept.
        case updated(Destination)
        case refused(String)
    }

    /// Put the card on the list. A card already listed refreshes what the card owns and keeps what
    /// the organisation set.
    static func apply(_ card: ExpertCard, to store: ExpertListStore) -> Outcome {
        if let problem = card.problem { return .refused(problem) }
        switch destination(organisationListIsManaged: store.organizationListIsManaged) {
        case .organisation:
            var list = store.deviceOwnerExperts
            let outcome: Outcome
            if let index = list.firstIndex(where: { $0.id == card.cardId }) {
                let kept = list[index]
                list[index] = EscalationContact(id: card.cardId, name: card.name, phone: card.phone,
                                                faceTimeHandle: card.faceTimeHandle, handoverChannel: card.handoverChannel,
                                                specialties: card.specialties, kind: kept.kind, onCall: kept.onCall,
                                                timeZoneIdentifier: kept.timeZoneIdentifier, rate: kept.rate)
                outcome = .updated(.organisation)
            } else {
                list.append(ownerEntry(card))
                outcome = .added(.organisation)
            }
            if let problem = store.setDeviceOwnerExperts(list) { return .refused(problem.message) }
            return outcome
        case .personal:
            var list = store.personalExperts
            let outcome: Outcome
            if let index = list.firstIndex(where: { $0.id == card.cardId }) {
                list[index] = personalEntry(card)
                outcome = .updated(.personal)
            } else {
                list.append(personalEntry(card))
                outcome = .added(.personal)
            }
            if let problem = store.setPersonalExperts(list) { return .refused(problem.message) }
            return outcome
        }
    }

    static func message(_ outcome: Outcome, name: String) -> String {
        switch outcome {
        case .added(.organisation):
            return "\(name) is on your experts list. Set their kind, hours and any rate in Settings → Field Assist → Experts."
        case .added(.personal):
            return "\(name) is on your own experts list."
        case .updated:
            return "\(name)'s card details are updated on your experts list."
        case .refused(let why):
            return "That card couldn't be added: \(why)."
        }
    }
}

/// A card waiting for the organisation's review before it goes on the list (Plan KM P2): opened
/// from a file, or scanned. Nothing is added until the review's own button.
@MainActor
final class ExpertCardInbox: ObservableObject {
    static let shared = ExpertCardInbox()

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let card: ExpertCard
    }

    @Published var pending: Pending?

    init() {}

    /// A card file iOS handed the app. Returns what to tell the user when it can't be read.
    func open(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defer { Self.discardInboxCopy(url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ExpertCardCodec.maximumBytes, let data = try? Data(contentsOf: url) else {
            return ExpertCardCodec.describe(.tooLarge)
        }
        return offer(ExpertCardCodec.read(data))
    }

    /// A scanned code's text.
    func scanned(_ text: String) -> String? {
        offer(ExpertCardCodec.read(code: text))
    }

    private func offer(_ result: Result<ExpertCard, ExpertCardCodec.ReadError>) -> String? {
        switch result {
        case .failure(let error): return ExpertCardCodec.describe(error)
        case .success(let card):
            pending = Pending(card: card)
            return nil
        }
    }

    private static func discardInboxCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
