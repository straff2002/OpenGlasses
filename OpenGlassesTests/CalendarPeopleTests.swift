import XCTest
@testable import OpenGlasses

/// Plan KT §9 — an event's people from EventKit, a Google calendar's presence, and a contact by
/// email address. All headless: EventKit and Contacts are behind copied-out records.
final class CalendarAttendeeMapperTests: XCTestCase {

    private func record(_ name: String?, _ url: String?, kind: EventKitParticipantRecord.Kind = .person,
                        status: EventKitParticipantRecord.Status = .accepted,
                        me: Bool = false) -> EventKitParticipantRecord {
        EventKitParticipantRecord(name: name, url: url.flatMap(URL.init(string:)), kind: kind, status: status,
                                  isCurrentUser: me)
    }

    func testTheAddressComesOutOfAMailtoURLOnly() {
        XCTAssertEqual(CalendarAttendeeMapper.email(from: URL(string: "mailto:Ana@Example.com")), "ana@example.com")
        XCTAssertEqual(CalendarAttendeeMapper.email(from: URL(string: "MAILTO:ana@example.com?subject=hi")),
                       "ana@example.com")
        XCTAssertEqual(CalendarAttendeeMapper.email(from: URL(string: "mailto:ana%2Bwork@example.com")),
                       "ana+work@example.com")
        XCTAssertNil(CalendarAttendeeMapper.email(from: URL(string: "https://example.com/ana")))
        XCTAssertNil(CalendarAttendeeMapper.email(from: URL(string: "mailto:nobody")))
        XCTAssertNil(CalendarAttendeeMapper.email(from: nil))
    }

    func testTheOrganiserComesFirstAndIsOnePersonWhenAlsoAnAttendee() {
        let people = CalendarAttendeeMapper.people(
            organizer: record("Tom Example", "mailto:tom@example.com"),
            attendees: [record("Sam Example", "mailto:sam@example.com", me: true),
                        record(nil, "mailto:TOM@example.com", status: .tentative),
                        record("Ana Example", "mailto:ana@example.com", status: .pending)])
        XCTAssertEqual(people, [
            CalendarPerson(name: "Tom Example", email: "tom@example.com", isOrganizer: true, response: .accepted),
            CalendarPerson(name: "Sam Example", email: "sam@example.com", isSelf: true, response: .accepted),
            CalendarPerson(name: "Ana Example", email: "ana@example.com", response: .pending),
        ])
    }

    func testRoomsAndResourcesAreNotPeopleAndANameThatIsTheAddressIsNoName() {
        let people = CalendarAttendeeMapper.people(
            organizer: nil,
            attendees: [record("Room 4", "mailto:room4@example.com", kind: .room),
                        record("Projector", "mailto:projector@example.com", kind: .resource),
                        record("lee@example.com", "mailto:lee@example.com", status: .declined),
                        record("Kim Example", nil, status: .unknown)])
        XCTAssertEqual(people, [
            CalendarPerson(name: nil, email: "lee@example.com", response: .declined),
            CalendarPerson(name: "Kim Example", email: nil, response: .unknown),
        ])
    }

    func testAnEventWithoutAttendeesStillBuildsAndHasNobody() {
        let event = MyDayCalendarEvent(id: "e", title: "Solo", startDate: Date(), endDate: Date(),
                                       isAllDay: false, location: nil)
        XCTAssertTrue(event.attendees.isEmpty)
        XCTAssertTrue(event.otherPeople.isEmpty)
        XCTAssertNil(event.organizer)
    }
}

final class GoogleCalendarPresenceTests: XCTestCase {

    func testGoogleAccountsAreNoticed() {
        let table: [(CalendarSourceRecord, Bool)] = [
            (.init(title: "Gmail", kind: .calDAV), true),
            (.init(title: "Google", kind: .calDAV), true),
            (.init(title: "someone@gmail.com", kind: .calDAV), true),
            (.init(title: "someone@googlemail.com", kind: .calDAV), true),
            (.init(title: "someone@example.com", kind: .calDAV), true),  // a Workspace account
            (.init(title: "iCloud", kind: .calDAV), false),
            (.init(title: "someone@icloud.com", kind: .calDAV), false),
            (.init(title: "someone@outlook.com", kind: .calDAV), false),
            (.init(title: "Gmail", kind: .exchange), false),
            (.init(title: "On My iPhone", kind: .local), false),
            (.init(title: "Holidays", kind: .subscribed), false),
            (.init(title: "Work Calendar", kind: .calDAV), false),
        ]
        for (source, google) in table {
            XCTAssertEqual(GoogleCalendarPresence.looksLikeGoogle(source), google, source.title)
        }
    }

    func testPresenceIsAnyGoogleAccount() {
        XCTAssertFalse(GoogleCalendarPresence.isPresent(in: []))
        XCTAssertFalse(GoogleCalendarPresence.isPresent(in: [.init(title: "iCloud", kind: .calDAV)]))
        XCTAssertTrue(GoogleCalendarPresence.isPresent(in: [.init(title: "iCloud", kind: .calDAV),
                                                            .init(title: "Gmail", kind: .calDAV)]))
    }
}

final class ContactByEmailTests: XCTestCase {
    private typealias Phone = ContactLookupHelper.PhoneEntry

    func testATextGoesToAMobileThenAnIPhoneThenAnythingButAFaxOrPager() {
        let home = Phone(number: "555-0101", rawLabel: "_$!<Home>!$_")
        let mobile = Phone(number: "555-0102", rawLabel: "_$!<Mobile>!$_")
        let iphone = Phone(number: "555-0103", rawLabel: "iPhone")
        let custom = Phone(number: "555-0104", rawLabel: "Boat")
        let fax = Phone(number: "555-0105", rawLabel: "_$!<WorkFAX>!$_")
        XCTAssertEqual(ContactLookupHelper.preferredPhone([home, iphone, mobile]), mobile)
        XCTAssertEqual(ContactLookupHelper.preferredPhone([home, iphone]), iphone)
        XCTAssertEqual(ContactLookupHelper.preferredPhone([home, custom]), custom)
        XCTAssertEqual(ContactLookupHelper.preferredPhone([home]), home)
        XCTAssertNil(ContactLookupHelper.preferredPhone([fax]))
        XCTAssertNil(ContactLookupHelper.preferredPhone([Phone(number: " ", rawLabel: nil)]))
        XCTAssertNil(ContactLookupHelper.preferredPhone([]))
    }

    func testAnAddressTwoPeopleShareIsNobody() {
        let ana = ContactLookupHelper.EmailContact(name: "Ana Example",
                                                   phones: [Phone(number: "555-0142", rawLabel: "_$!<Mobile>!$_")])
        let anaAgain = ContactLookupHelper.EmailContact(name: "ana example", phones: [])
        let lee = ContactLookupHelper.EmailContact(name: "Lee Example", phones: [])
        XCTAssertEqual(ContactLookupHelper.pickContact(from: [ana, anaAgain]), ana)
        XCTAssertNil(ContactLookupHelper.pickContact(from: [ana, lee]))
        XCTAssertNil(ContactLookupHelper.pickContact(from: []))
        XCTAssertEqual(ana.textablePhone, "555-0142")
        XCTAssertNil(lee.textablePhone)
    }

    func testTheDisplayNameFallsBackToTheOrganisation() {
        XCTAssertEqual(ContactLookupHelper.displayName(given: "Ana", family: "Example", organization: "Co"), "Ana Example")
        XCTAssertEqual(ContactLookupHelper.displayName(given: "", family: "", organization: "Example Co"), "Example Co")
    }

    func testANonAddressResolvesToNobodyWithoutTouchingContacts() {
        XCTAssertNil(ContactLookupHelper.resolve(email: "not an address"))
    }
}
