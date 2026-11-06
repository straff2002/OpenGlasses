import XCTest
@testable import OpenGlasses

/// Plan KM P2 — the technician's side of a time reply, and the expert card: a reply is attached
/// only for a handover this phone sent, from the expert it went to; an imported card fills the list
/// entry, and a reply from that card matches it exactly.
///
/// Every name, number and company here is invented.
@MainActor
final class ExpertReplyAndCardTests: XCTestCase {

    private var directory: URL!
    private var clock: AssistingTestClock!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = AssistingFixture.temporaryDirectory("expert-reply")
        clock = AssistingTestClock()
        suite = "expert-reply-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The expert's side: open the generations, take, Done, and the reply.
    private func reply(for handovers: [ExpertHandover], card: ExpertCard? = nil, minutes: TimeInterval = 900) throws -> ExpertTimeReply {
        let testClock = clock!
        let store = AssistingHandoverStore(directory: directory.appendingPathComponent(UUID().uuidString), now: { testClock.now })
        for handover in handovers { store.open(AssistingFixture.opened(handover)) }
        let id = try XCTUnwrap(handovers.first?.handoverId)
        store.take(id: id)
        clock.advance(minutes)
        store.done(id: id)
        return try ExpertTimeReply.build(for: XCTUnwrap(store.handover(id: id)), card: card, note: " Swap the switch. ",
                                         now: clock.now).get()
    }

    /// The technician's job, with what it sent.
    private func job(sent: [ExpertHandoverSent], id: String = "job-s1") -> FieldSession {
        var session = AssistingFixture.session()
        session = FieldSession(id: id, vaultId: session.vaultId, assetId: nil, mode: .aiOnly, startedAt: session.startedAt,
                               outcome: .inProgress, escalations: [], billableSeconds: 0)
        session.jobReference = "4471"
        session.expertHandovers = sent
        return session
    }

    // MARK: - Accepted only for a handover this phone sent

    func testAReplyToAHandoverThisPhoneSentIsAttachedWithItsMinutesAndNote() throws {
        let g1 = AssistingFixture.handover(generation: 1)
        let g2 = AssistingFixture.handover(generation: 2)
        let reply = try reply(for: [g1, g2])
        let match = try ExpertReplyMatch.match(reply, sessions: [job(sent: [AssistingFixture.sent(g1), AssistingFixture.sent(g2)])],
                                               now: clock.now).get()
        XCTAssertEqual(match.sessionId, "job-s1")
        XCTAssertEqual(match.received.minutes, 15)
        XCTAssertEqual(match.received.generationsSeen, [1, 2])
        XCTAssertEqual(match.received.note, "Swap the switch.")
        XCTAssertEqual(match.received.matchedBy, .listEntry)
        XCTAssertEqual(match.received.expert.name, "Sam Ferreira", "named as this phone's own record names them")
        XCTAssertTrue(ExpertReplyMatch.confirmation(match.received, jobReference: "4471").contains("15 minutes"))

        // Kept on the job, and the job still decodes.
        var session = job(sent: [AssistingFixture.sent(g1)])
        session.expertReplies = [match.received]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(FieldSession.self, from: encoder.encode(session))
        XCTAssertEqual(back.expertReplies, [match.received])
        XCTAssertFalse(String(decoding: try encoder.encode(job(sent: [])), as: UTF8.self).contains("expertReplies"),
                       "absent when none were received")
        XCTAssertTrue(ExpertReplyMatch.isDuplicate(match.received, of: [match.received]), "the same reply twice is one reply")
    }

    func testAReplyWithAnUnknownHandoverIdIsRefused() throws {
        let reply = try reply(for: [AssistingFixture.handover(id: "H-other")])
        let sessions = [job(sent: [AssistingFixture.sent(AssistingFixture.handover(id: "H-1"))])]
        XCTAssertEqual(ExpertReplyMatch.match(reply, sessions: sessions, now: clock.now).failureValue, .unknownHandover)
        XCTAssertEqual(ExpertReplyMatch.match(reply, sessions: [], now: clock.now).failureValue, .unknownHandover)
    }

    func testAReplyFromAnotherSenderIsRefused() throws {
        // The same handover id, but the expert's app says it was addressed to someone else.
        let sentToSam = AssistingFixture.handover(expertId: "sam")
        let reply = try reply(for: [AssistingFixture.handover(expertId: "priya", expertName: "Priya Lindqvist")])
        XCTAssertEqual(ExpertReplyMatch.match(reply, sessions: [job(sent: [AssistingFixture.sent(sentToSam)])], now: clock.now).failureValue,
                       .otherSender)
    }

    func testAReplyClaimingAnUpdateThisPhoneNeverSentIsRefused() throws {
        let reply = try reply(for: [AssistingFixture.handover(generation: 1), AssistingFixture.handover(generation: 2)])
        let sessions = [job(sent: [AssistingFixture.sent(AssistingFixture.handover(generation: 1))])]
        XCTAssertEqual(ExpertReplyMatch.match(reply, sessions: sessions, now: clock.now).failureValue, .generationNotSent)
    }

    // MARK: - The expert card

    func testTheCardCarriesNoKindHoursOrRateAndDropsOnesAddedByHand() throws {
        let card = ExpertCard(name: "  Sam Ferreira ", phone: "+64 21 000 1111", faceTimeHandle: "sam@example.com",
                              handoverChannel: .messages, specialties: ["furnace", "Furnace", "heat pump"],
                              licences: ["Gas, Riverton region\nRefrigerant handling"])
        XCTAssertNil(card.problem)
        XCTAssertEqual(card.name, "Sam Ferreira")
        XCTAssertEqual(card.specialties, ["furnace", "heat pump"])
        XCTAssertEqual(card.licences, ["Gas, Riverton region", "Refrigerant handling"])
        XCTAssertTrue(ExpertCard.isCardId(card.cardId))
        let labels = Set(Mirror(reflecting: card).children.compactMap(\.label))
        XCTAssertTrue(labels.isDisjoint(with: ["kind", "rate", "onCall", "timeZoneIdentifier"]))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ExpertCardCodec.fileData(card)) as? [String: Any])
        object["kind"] = "contracted"
        object["rate"] = ["perHour": 999, "minimumMinutes": 0, "roundingMinutes": 1, "currency": "XTS"]
        let doctored = try ExpertCardCodec.read(JSONSerialization.data(withJSONObject: object)).get()
        XCTAssertEqual(doctored, card, "a kind or rate written into a card is ignored, never applied")
    }

    func testTheCardRoundTripsAsAFileAndAsACode() throws {
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111", specialties: ["furnace"])
        XCTAssertEqual(try ExpertCardCodec.read(ExpertCardCodec.fileData(card)).get(), card)
        let code = try XCTUnwrap(ExpertCardCodec.codeText(card))
        XCTAssertLessThanOrEqual(code.utf8.count, ExpertCard.maxCodeBytes)
        XCTAssertEqual(try ExpertCardCodec.read(code: code).get(), card)
        XCTAssertEqual(ExpertCardCodec.fileName(card), "sam-ferreira.ogexpert")

        let long = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111",
                              specialties: (0..<20).map { "specialty number \($0) of many" },
                              licences: (0..<10).map { String(repeating: "licensed for region \($0) ", count: 3) })
        XCTAssertNil(ExpertCardCodec.codeText(long), "too long for a code a phone reads easily; the file still works")
        XCTAssertNoThrow(try ExpertCardCodec.read(ExpertCardCodec.fileData(long)).get())

        XCTAssertEqual(ExpertCardCodec.read(Data("{\"type\":\"openglasses.job\"}".utf8)).failureValue, .notACard)
        let unreachable = ExpertCard(name: "Sam Ferreira")
        guard case .refused = ExpertCardCodec.read(ExpertCardCodec.fileData(unreachable)).failureValue else {
            return XCTFail("a card nobody can call can't be used")
        }
    }

    func testAnImportedCardFillsTheListEntryAndAReplyMatchesIt() throws {
        // The organisation's phone, with no profile: the device owner's list.
        let list = ExpertListStore(defaults: defaults, profileList: { nil })
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111", faceTimeHandle: "sam@example.com",
                              handoverChannel: .whatsApp, specialties: ["furnace"])
        XCTAssertEqual(ExpertCardImport.apply(card, to: list), .added(.organisation))
        let entry = try XCTUnwrap(list.entries.first)
        XCTAssertEqual(entry.id, card.cardId, "listed under the card's own id")
        XCTAssertEqual(entry.contact.name, "Sam Ferreira")
        XCTAssertEqual(entry.contact.phone, "+64 21 000 1111")
        XCTAssertEqual(entry.contact.faceTimeHandle, "sam@example.com")
        XCTAssertEqual(entry.contact.handoverChannel, .whatsApp)
        XCTAssertEqual(entry.contact.specialties, ["furnace"])
        XCTAssertEqual(entry.contact.kind, .staff, "the organisation sets the kind, not the card")
        XCTAssertNil(entry.contact.rate)

        // The organisation makes them contracted with a rate; a refreshed card keeps that.
        let rate = EscalationContact.Rate(perHour: 50, minimumMinutes: 30, roundingMinutes: 15, currency: "XTS")
        let contracted = EscalationContact(id: entry.id, name: entry.contact.name, phone: entry.contact.phone,
                                           faceTimeHandle: entry.contact.faceTimeHandle, handoverChannel: .whatsApp,
                                           specialties: ["furnace"], kind: .contracted, rate: rate)
        XCTAssertNil(list.setDeviceOwnerExperts([contracted]))
        let refreshed = ExpertCard(cardId: card.cardId, name: "Sam Ferreira", phone: "+64 21 000 9999",
                                   specialties: ["furnace", "boilers"])
        XCTAssertEqual(ExpertCardImport.apply(refreshed, to: list), .updated(.organisation))
        XCTAssertEqual(list.entries.first?.contact.phone, "+64 21 000 9999")
        XCTAssertEqual(list.entries.first?.contact.kind, .contracted)
        XCTAssertEqual(list.entries.first?.contact.rate, rate)
        XCTAssertEqual(list.entries.count, 1)

        // A handover to that entry, and the expert's reply carrying the card, match exactly.
        let handover = AssistingFixture.handover(expertId: entry.id, expertName: entry.contact.name)
        let session = job(sent: [AssistingFixture.sent(handover, expert: list.entries[0].contact.snapshot)])
        let fromCard = try reply(for: [handover], card: card)
        let match = try ExpertReplyMatch.match(fromCard, sessions: [session], now: clock.now).get()
        XCTAssertEqual(match.received.matchedBy, .card)
        XCTAssertEqual(match.received.expert.id, card.cardId)

        // The same handover answered without the card, or by another card, is not them.
        let withoutCard = try reply(for: [handover], card: nil)
        XCTAssertEqual(ExpertReplyMatch.match(withoutCard, sessions: [session], now: clock.now).failureValue, .cardMismatch)
        let otherCard = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111")
        let impostor = try reply(for: [handover], card: otherCard)
        XCTAssertEqual(ExpertReplyMatch.match(impostor, sessions: [session], now: clock.now).failureValue, .cardMismatch)
    }

    func testUnderAProfileACardBecomesTheTechniciansOwnStaffAddition() throws {
        let managed = ExpertListStore(defaults: defaults, profileList: { [] })
        let card = ExpertCard(name: "Dana Whitcombe", phone: "+64 21 000 3333", specialties: ["refrigeration"])
        XCTAssertEqual(ExpertCardImport.apply(card, to: managed), .added(.personal))
        let entry = try XCTUnwrap(managed.entries.first)
        XCTAssertEqual(entry.source, .personal)
        XCTAssertEqual(entry.id, card.cardId)
        XCTAssertEqual(entry.contact.kind, .staff)
        XCTAssertNil(entry.contact.rate)
    }

    // MARK: - The expert's own card store

    func testTheExpertsOwnCardIsKeptAndRemoved() {
        let store = ExpertCardStore(defaults: defaults)
        XCTAssertNil(store.card)
        XCTAssertNotNil(store.save(ExpertCard(name: "No Number")), "a card nobody can call is refused")
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111")
        XCTAssertNil(store.save(card))
        XCTAssertEqual(store.card, card)
        store.remove()
        XCTAssertNil(store.card)
        XCTAssertEqual(SensitiveStore.expertCard.record.deleteAll, .api("ExpertCardStore.remove()"))
    }

    func testTheCardTypeIsDeclaredAndOpensAsACopy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let type = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == ExpertCard.utiIdentifier })
        let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [ExpertCard.fileExtension])
        XCTAssertEqual(tags["public.mime-type"] as? [String], [ExpertCard.mimeType])
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains(ExpertCard.utiIdentifier) == true })
        XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, false)
        XCTAssertTrue(ExpertCardCodec.isCardFile(URL(fileURLWithPath: "/tmp/sam.ogexpert")))
        XCTAssertFalse(ExpertCardCodec.isCardFile(URL(fileURLWithPath: "/tmp/job.ogcase")))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
