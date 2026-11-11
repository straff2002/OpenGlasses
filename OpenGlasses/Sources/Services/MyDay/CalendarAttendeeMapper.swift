import Foundation

// Plan KT §9.3 — an event's people, from EventKit, the same for every account iOS Calendar syncs.
// `EKParticipant` cannot be made outside EventKit, so `EventKitDayStore` copies each one into an
// `EventKitParticipantRecord` and everything that decides lives here, headless.

/// What `EKParticipant` says about one participant, copied out of EventKit.
struct EventKitParticipantRecord: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case person
        case room
        case resource
        case group
        case unknown
    }

    enum Role: Equatable, Sendable {
        case required
        case optional
        case chair
        case nonParticipant
        case unknown
    }

    enum Status: Equatable, Sendable {
        case accepted
        case declined
        case tentative
        case pending
        case delegated
        case completed
        case inProcess
        case unknown
    }

    let name: String?
    /// Usually `mailto:someone@example.com`.
    let url: URL?
    let kind: Kind
    let role: Role
    let status: Status
    let isCurrentUser: Bool

    init(name: String?, url: URL?, kind: Kind = .person, role: Role = .required,
         status: Status = .unknown, isCurrentUser: Bool = false) {
        self.name = name
        self.url = url
        self.kind = kind
        self.role = role
        self.status = status
        self.isCurrentUser = isCurrentUser
    }
}

enum CalendarAttendeeMapper {

    /// The event's people: the organiser first (when there is one), then the attendees in the
    /// order the calendar gave them. Rooms and resources are dropped. One person listed twice — an
    /// organiser who is also an attendee, or one address in two cases — is one person, carrying
    /// the organiser flag if either entry had it.
    static func people(organizer: EventKitParticipantRecord?,
                       attendees: [EventKitParticipantRecord]) -> [CalendarPerson] {
        var result: [CalendarPerson] = []
        var indexByEmail: [String: Int] = [:]

        func add(_ record: EventKitParticipantRecord, isOrganizer: Bool) {
            guard record.kind != .room, record.kind != .resource else { return }
            let email = self.email(from: record.url)
            let person = CalendarPerson(name: cleanedName(record.name, email: email),
                                        email: email,
                                        isOrganizer: isOrganizer,
                                        isSelf: record.isCurrentUser,
                                        response: response(record.status))
            if let email, let index = indexByEmail[email] {
                let existing = result[index]
                result[index] = CalendarPerson(name: existing.name ?? person.name,
                                               email: email,
                                               isOrganizer: existing.isOrganizer || isOrganizer,
                                               isSelf: existing.isSelf || person.isSelf,
                                               response: existing.response == .unknown
                                                   ? person.response : existing.response)
                return
            }
            if let email { indexByEmail[email] = result.count }
            result.append(person)
        }

        if let organizer { add(organizer, isOrganizer: true) }
        for attendee in attendees { add(attendee, isOrganizer: false) }
        return result
    }

    /// The address in a `mailto:` URL, lower-cased; nil for any other URL or a malformed one.
    static func email(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        var address = url.absoluteString.dropFirst("mailto:".count)
        if let query = address.firstIndex(of: "?") { address = address[..<query] }
        let decoded = String(address).removingPercentEncoding ?? String(address)
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else { return nil }
        return trimmed
    }

    /// The calendar's name for the person, trimmed. Some servers fill the name with the address
    /// itself; that is no name.
    private static func cleanedName(_ name: String?, email: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let email, trimmed.lowercased() == email { return nil }
        return trimmed
    }

    private static func response(_ status: EventKitParticipantRecord.Status) -> CalendarPerson.Response {
        switch status {
        case .accepted, .completed, .inProcess: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending, .delegated: .pending
        case .unknown: .unknown
        }
    }
}

extension MyDayCalendarEvent {
    /// Everybody on the event but the wearer.
    var otherPeople: [CalendarPerson] { attendees.filter { !$0.isSelf } }

    /// The organiser, when the calendar names one.
    var organizer: CalendarPerson? { attendees.first(where: \.isOrganizer) }
}
