import XCTest
@testable import OpenGlasses

/// Plan KT P4 — the Today glance's Medical Compliance rule on the day's cards: under any Medical
/// Compliance mode the lens, the watch and speech withhold what an appointment is (the event's
/// title, the meeting's agreed items and a draft that names the meeting), and keep the times. The
/// phone's My Day page is the wearer's own screen and, like the existing My Day page, shows them.
@MainActor
final class PreparedCardMedicalTests: XCTestCase {

    private let title = "Gig at the Example Hall"
    private let meeting = "Example review"
    private let planning = "Example planning"

    private func texts(_ screen: HUDScreen?) -> [String] {
        guard let screen else { return [] }
        let title: [String] = [screen.title].compactMap { $0 }
        return title + screen.lines.map(\.text) + screen.items.map(\.label)
    }

    // MARK: - The rule

    func testAnyMedicalComplianceModeWithholdsLikeTheTodayGlance() {
        XCTAssertFalse(PreparedCardMedicalWithholding.applies(.off))
        XCTAssertTrue(PreparedCardMedicalWithholding.applies(MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false)))
        XCTAssertTrue(PreparedCardMedicalWithholding.applies(.localOnly))
    }

    func testWhatIsWithheldPerKind() {
        let leaveBy = PreparedCardMedicalWithholding.shown(LensCardFixtures.leaveBy, withholding: true)
        XCTAssertNil(leaveBy.subject, "the event's title")
        XCTAssertEqual(leaveBy.headline, "Leave by 18:15", "the time stays")
        XCTAssertEqual(leaveBy.facts, LensCardFixtures.leaveBy.facts)
        XCTAssertEqual(leaveBy.draft, LensCardFixtures.leaveBy.draft, "the draft itself is never altered")
        XCTAssertEqual(leaveBy.id, LensCardFixtures.leaveBy.id)

        let shortNight = PreparedCardMedicalWithholding.shown(LensCardFixtures.shortNight, withholding: true)
        XCTAssertEqual(shortNight.headline, "Ask to move a meeting")
        XCTAssertNil(shortNight.subject)
        XCTAssertTrue(PreparedCardMedicalWithholding.withholdsDraftText(LensCardFixtures.shortNight, withholding: true))

        let followUp = PreparedCardMedicalWithholding.shown(LensCardFixtures.meetingFollowUp, withholding: true)
        XCTAssertNil(followUp.subject)
        XCTAssertTrue(followUp.facts.isEmpty, "the agreed items say what the meeting was")
        XCTAssertEqual(followUp.signals.first?.text, "3 things agreed", "a count stays")
        XCTAssertTrue(PreparedCardMedicalWithholding.withholdsDraftText(LensCardFixtures.meetingFollowUp, withholding: true))

        for card in [LensCardFixtures.fitItIn, LensCardFixtures.jobOnMyWay, LensCardFixtures.jobReportOwed] {
            XCTAssertEqual(PreparedCardMedicalWithholding.shown(card, withholding: true), card,
                           "\(card.kind): not a calendar appointment, as the job day's own surfaces")
        }
        XCTAssertFalse(PreparedCardMedicalWithholding.withholdsDraftText(LensCardFixtures.leaveBy, withholding: true),
                       "an on-my-way text does not name the event")
        for card in LensCardFixtures.all {
            XCTAssertEqual(PreparedCardMedicalWithholding.shown(card, withholding: false), card, "off: unchanged")
        }
    }

    // MARK: - The lens

    func testTheLensStackWithholdsTheTitle() {
        let shortNight = PreparedCardHUDBuilder.stack([LensCardFixtures.shortNight], index: 0, geometry: .raybanDisplay,
                                                      withholding: true) { _ in }
        XCTAssertEqual(shortNight?.title, "Ask to move a meeting")
        XCTAssertFalse(texts(shortNight).contains { $0.contains(meeting) })

        // A leave-by with no fact left to show falls back to its subject — not under Medical Compliance.
        let bare = PreparedCard(id: LensCardFixtures.leaveBy.id, headline: "Leave now", subject: title,
                                signals: [], facts: [], primary: LensCardFixtures.leaveBy.primary,
                                urgency: .immediate, dueAt: nil, validUntil: LensCardFixtures.validUntil)
        let open = PreparedCardHUDBuilder.stack([bare], index: 0, geometry: .raybanDisplay) { _ in }
        XCTAssertTrue(texts(open).contains { $0.contains(title) }, "without Medical Compliance the subject shows")
        let withheld = PreparedCardHUDBuilder.stack([bare], index: 0, geometry: .raybanDisplay, withholding: true) { _ in }
        XCTAssertFalse(texts(withheld).contains { $0.contains(title) })

        let followUp = PreparedCardHUDBuilder.stack([LensCardFixtures.meetingFollowUp], index: 0,
                                                    geometry: .raybanDisplay, withholding: true) { _ in }
        XCTAssertFalse(texts(followUp).contains { $0.contains("Example Co") || $0.contains(planning) })
    }

    func testTheLensDraftIsHiddenButStillStages() {
        var presses: [PreparedCardLensAction] = []
        let screen = PreparedCardHUDBuilder.draft(LensCardFixtures.shortNight, page: 0, geometry: .raybanDisplay,
                                                  withholding: true) { presses.append($0.action) }
        XCTAssertFalse(texts(screen).contains { $0.contains("Could we move") || $0.contains(meeting) })
        XCTAssertTrue(texts(screen).joined(separator: " ").contains("Read it on your phone"))
        XCTAssertEqual(PreparedCardHUDBuilder.draftPages(LensCardFixtures.shortNight, geometry: .raybanDisplay,
                                                         withholding: true).count, 1)
        screen?.items.first { $0.id == PreparedCardHUDBuilder.ItemID.send }?.action()
        XCTAssertEqual(presses, [.sendOnPhone], "Send on phone is there: the phone shows the whole message")

        let leaveBy = PreparedCardHUDBuilder.draft(LensCardFixtures.leaveBy, page: 0, geometry: .raybanDisplay,
                                                   withholding: true) { _ in }
        XCTAssertTrue(texts(leaveBy).joined(separator: " ").contains("On my way"), "a text that names nothing shows")
    }

    func testTheLensGlanceWithholdsTheTitle() {
        let card = PreparedCard(id: LensCardFixtures.runningLate.id, headline: "Running about 10 min late",
                                subject: title, signals: [], facts: [], primary: LensCardFixtures.runningLate.primary,
                                urgency: .immediate, dueAt: nil, validUntil: LensCardFixtures.validUntil)
        let open = PreparedCardHUDBuilder.glance(card, geometry: .raybanDisplay) { _ in }
        XCTAssertTrue(texts(open).contains { $0.contains(title) })
        let withheld = PreparedCardHUDBuilder.glance(card, geometry: .raybanDisplay, withholding: true) { _ in }
        XCTAssertFalse(texts(withheld).contains { $0.contains(title) })
    }

    // MARK: - The watch

    func testTheWatchPayloadWithholdsTheTitleAndTheDraftThatNamesIt() {
        let cards = WatchPreparedCardBuilder.cards(from: [LensCardFixtures.leaveBy, LensCardFixtures.meetingFollowUp],
                                                   now: CardFixtures.at(9), withholding: true)
        let encoded = cards.map { card in
            ([card.headline] + card.chips.map(\.text) + card.facts.map(\.value) + [card.draftText ?? ""])
                .joined(separator: " ")
        }.joined(separator: " ")
        XCTAssertFalse(encoded.contains(title))
        XCTAssertFalse(encoded.contains(planning))
        XCTAssertFalse(encoded.contains("Example Co sends"), "no agreed item, in a fact or the draft")
        XCTAssertEqual(cards.last?.draftWithheld, true)
        XCTAssertNil(cards.last?.draftText)
        XCTAssertEqual(cards.first?.draftText, "On my way — there about 18:45.")
    }

    // MARK: - Speech

    func testSpeechWithholdsTheTitle() {
        let leaveBy = PreparedCardPhraser.phrase(LensCardFixtures.leaveBy, withholding: true)
        XCTAssertEqual(leaveBy.statement, "Leave by 18:15 — Rain from 18:00.")
        XCTAssertFalse(leaveBy.text.contains(title))
        let late = PreparedCardPhraser.phrase(LensCardFixtures.runningLate, withholding: true)
        XCTAssertFalse(late.text.contains(title))
        XCTAssertEqual(late.offer, "Want me to get a message to Ana ready?")
        XCTAssertEqual(PreparedCardPhraser.draftReading(LensCardFixtures.shortNight, withholding: true),
                       PreparedCardMedicalWithholding.draftHiddenLine, "Read it does not say a draft that names the meeting")
        XCTAssertEqual(PreparedCardPhraser.draftReading(LensCardFixtures.leaveBy, withholding: true),
                       "To Ana Example: On my way — there about 18:45.")
        let reading = PreparedCardSpokenStack(cards: [LensCardFixtures.leaveBy], withholding: true, now: CardFixtures.at(9))
        XCTAssertFalse(reading?.opening().contains(title) ?? true)
    }

    // MARK: - The phone page: unchanged

    func testThePhonePageShowsWhatTheExistingMyDayPageShows() {
        let model = PreparedCardPresentation.model(LensCardFixtures.leaveBy, memory: nil, changedDraft: nil,
                                                   now: CardFixtures.at(9), calendar: CardFixtures.calendar)
        XCTAssertEqual(model.subject, title, "the wearer's own screen; My Day's rows show titles under Medical Compliance too")
    }
}
