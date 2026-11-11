import XCTest
@testable import OpenGlasses

/// Plan KT §1 — the shared card model: ids, limits, and a round trip through JSON (what the store
/// and the watch payload will carry).
final class PreparedCardModelTests: XCTestCase {
    private typealias F = CardFixtures

    func testIDsRoundTripThroughTheirRawValue() throws {
        let id = PreparedCardID(kind: .leaveBy, occurrence: "event:with:colons:2026-11-12")
        XCTAssertEqual(id.rawValue, "leaveBy:event:with:colons:2026-11-12")
        XCTAssertEqual(PreparedCardID(rawValue: id.rawValue), id)
        XCTAssertNil(PreparedCardID(rawValue: "noSuchKind:x"))
        XCTAssertNil(PreparedCardID(rawValue: "leaveBy"))

        let data = try JSONEncoder().encode([id])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["leaveBy:event:with:colons:2026-11-12"]"#)
        XCTAssertEqual(try JSONDecoder().decode([PreparedCardID].self, from: data), [id])
        XCTAssertThrowsError(try JSONDecoder().decode([PreparedCardID].self, from: Data(#"["nope"]"#.utf8)))
    }

    func testACardRoundTripsWithEveryAction() throws {
        let actions: [PreparedAction] = [
            .handOff(.init(channel: .whatsapp)), .directions(destination: "1 Example Street", mode: .transit),
            .openEvent(id: "e"), .openJob(id: "j"), .openReport(sessionId: "s"), .openPartsOrder(sessionId: "s"),
            .getSignOff(sessionId: "s"),
            .addToCalendar(ProposedEvent(title: "Coffee", start: F.at(10), end: F.at(11), location: nil)),
            .call(ContactRef(name: "Ana Example", phone: "555-0142")), .complete(reminderId: "r"), .later, .dismiss,
        ]
        let draft = PreparedDraft(channel: .email,
                                  recipient: DraftRecipient(name: "Ana Example", addresses: ["ana@example.com"],
                                                            source: .calendarAttendee),
                                  subject: "Gig", text: "On my way.", origin: .cloud(provider: "Example"),
                                  language: "en-GB")
        for action in actions {
            let card = PreparedCard(id: PreparedCardID(kind: .leaveBy, occurrence: "gig:2026-11-12"),
                                    headline: "Leave by 18:15", subject: "Gig",
                                    signals: [CardSignal(source: .calendar, text: "19:00")],
                                    facts: [CardFact(label: "Leave by", value: "18:15")], primary: action,
                                    secondary: [.later], draft: draft, urgency: .important, dueAt: F.at(18, 15),
                                    validUntil: F.at(19), absorbs: [.jobDay("unsent-s1")])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            XCTAssertEqual(try decoder.decode(PreparedCard.self, from: encoder.encode(card)), card, "\(action)")
        }
        let states: [PreparedCardState] = [.fresh, .seen, .later(until: F.at(12)),
                                           .handedOff(at: F.at(9), result: .unknown), .done, .dismissed, .notUseful]
        for state in states {
            let memory = PreparedCardMemory(state: state, editedText: "mine", changedAt: F.at(9))
            XCTAssertEqual(try JSONDecoder().decode(PreparedCardMemory.self, from: JSONEncoder().encode(memory)), memory)
        }
    }

    func testTheCardKeepsItsLimits() {
        let long = String(repeating: "x", count: 100)
        let card = PreparedCard(
            id: PreparedCardID(kind: .fitItIn, occurrence: "r"), headline: long, subject: long,
            signals: (0..<5).map { CardSignal(source: .calendar, text: "chip \($0) \(long)") },
            facts: (0..<6).map { CardFact(label: "\($0)", value: "v") },
            primary: .dismiss, secondary: [.later, .dismiss, .later],
            urgency: .routine, dueAt: nil, validUntil: F.at(12))
        XCTAssertEqual(card.headline.count, PreparedCard.headlineLimit)
        XCTAssertTrue(card.headline.hasSuffix("…"))
        XCTAssertEqual(card.subject?.count, PreparedCard.subjectLimit)
        XCTAssertEqual(card.signals.count, 3)
        XCTAssertTrue(card.signals.allSatisfy { $0.text.count <= CardSignal.maximumLength })
        XCTAssertEqual(card.facts.count, 4)
        XCTAssertEqual(card.secondary.count, 2)
        XCTAssertEqual(PreparedCardText.clipped("  short  ", to: 40), "short")
    }

    func testACardIsAsSensitiveAsItsMostSensitiveChip() {
        let card = PreparedCard(id: PreparedCardID(kind: .shortNight, occurrence: "m"), headline: "h", subject: nil,
                                signals: [CardSignal(source: .calendar, text: "08:00"),
                                          CardSignal(source: .sleep, text: "Slept 5h", sensitivity: .health)],
                                facts: [], primary: .dismiss, urgency: .upcoming, dueAt: nil, validUntil: F.at(12))
        XCTAssertEqual(card.sensitivity, .health)
        XCTAssertLessThan(CardSensitivity.ordinary, .personal)
        XCTAssertLessThan(CardSensitivity.personal, .health)
    }

    func testUrgencyKeepsMyDaysLadderAndCodesAsItsNumber() throws {
        XCTAssertLessThan(MyDayUrgency.routine, .upcoming)
        XCTAssertLessThan(MyDayUrgency.important, .immediate)
        XCTAssertEqual(String(data: try JSONEncoder().encode([MyDayUrgency.immediate]), encoding: .utf8), "[3]")
    }

    func testOnlyShortNightIsOptIn() {
        XCTAssertEqual(PreparedCardKind.allCases.filter(\.isOptIn), [.shortNight])
        XCTAssertEqual(PreparedCardKind.allCases.filter(\.isJobKind),
                       [.jobRunningLate, .jobOnMyWay, .jobReportOwed, .jobPartsOwed, .jobSignOffOwed])
    }
}
