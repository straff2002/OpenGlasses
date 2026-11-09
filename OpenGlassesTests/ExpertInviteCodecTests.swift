import XCTest
@testable import OpenGlasses

final class ExpertInviteCodecTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.7)

    private func invite(org: String = "Northside Heating", by: String = "Pat", replyTo: String? = "pat@example.test")
        -> ExpertInvite {
        ExpertInvite(inviteId: "invite-1234", organisation: org, invitedBy: by, replyTo: replyTo, created: t0)
    }

    func testRoundTrip() throws {
        let original = invite()
        let read = try ExpertInviteCodec.read(ExpertInviteCodec.fileData(original)).get()
        XCTAssertEqual(read, original)
        XCTAssertEqual(read.expires.timeIntervalSince(read.created), TimeInterval(ExpertInvite.validDays) * 86_400)
    }

    func testAnInviteIsNotACardAndACardIsNotAnInvite() {
        let card = ExpertCard(cardId: "card-1", name: "Sam Ferreira", phone: "+64 21 555 0100")
        XCTAssertTrue(ExpertInviteCodec.isInvite(ExpertInviteCodec.fileData(invite())))
        XCTAssertFalse(ExpertInviteCodec.isInvite(ExpertCardCodec.fileData(card)))
        XCTAssertEqual(ExpertCardCodec.read(ExpertInviteCodec.fileData(invite())), .failure(.notACard))
        XCTAssertEqual(ExpertInviteCodec.read(ExpertCardCodec.fileData(card)), .failure(.notACard))
    }

    func testAPhoneWithNoOrganisationNameUsesWhoSentIt() throws {
        let read = try ExpertInviteCodec.read(ExpertInviteCodec.fileData(invite(org: ""))).get()
        XCTAssertEqual(read.senderName, "Pat")
    }

    func testAnInviteFromNobodyIsRefusedByName() {
        XCTAssertEqual(ExpertInviteCodec.read(ExpertInviteCodec.fileData(invite(org: "", by: " "))),
                       .failure(.refused("it doesn't say who it's from")))
    }

    func testFieldsItDoesntKnowAreDropped() throws {
        let json = """
        {"type":"openglasses.expert-invite","version":1,"id":"invite-1234","organisation":"Northside Heating",
         "invitedBy":"Pat","created":"2027-01-15T08:00:00Z","expires":"2027-02-14T08:00:00Z","rate":"120/h"}
        """
        let read = try ExpertInviteCodec.read(Data(json.utf8)).get()
        XCTAssertEqual(read.organisation, "Northside Heating")
        XCTAssertFalse(String(decoding: ExpertInviteCodec.fileData(read), as: UTF8.self).contains("rate"))
    }

    func testDatesPastThirtyDaysAreRefused() {
        let long = ExpertInvite(inviteId: "invite-1234", organisation: "Northside Heating", invitedBy: "Pat",
                                replyTo: nil, created: t0, expires: t0.addingTimeInterval(90 * 86_400))
        XCTAssertEqual(ExpertInviteCodec.read(ExpertInviteCodec.fileData(long)),
                       .failure(.refused("its dates aren't ones this app writes")))
    }

    func testANewerVersionIsRefusedByName() {
        let json = """
        {"type":"openglasses.expert-invite","version":2,"id":"invite-1234","organisation":"Northside Heating",
         "invitedBy":"Pat","created":"2027-01-15T08:00:00Z","expires":"2027-02-14T08:00:00Z"}
        """
        XCTAssertEqual(ExpertInviteCodec.read(Data(json.utf8)),
                       .failure(.refused("it was made by a newer version of the app")))
    }

    func testExpiry() {
        let made = invite()
        XCTAssertFalse(made.isExpired(at: made.created))
        XCTAssertTrue(made.isExpired(at: made.expires))
    }

    func testControlCharactersAndNewlinesAreStripped() {
        let messy = invite(org: "North\nside\u{7}", by: "Pat\t")
        XCTAssertEqual(messy.organisation, "Northside")
        XCTAssertEqual(messy.invitedBy, "Pat")
    }

    func testFileNameNamesTheSender() {
        XCTAssertEqual(ExpertInviteCodec.fileName(invite()), "invite-northside-heating.ogexpert")
        XCTAssertEqual(ExpertInviteCodec.fileName(invite(org: "", by: "")), "invite.ogexpert")
    }

    // MARK: - A card answering an invite

    func testACardAnsweringAnInviteStillReadsAsTheSameCard() throws {
        let card = ExpertCard(cardId: "card-1", name: "Sam Ferreira", phone: "+64 21 555 0100")
        let data = ExpertInviteCodec.cardFileData(card, answering: "invite-1234")
        XCTAssertEqual(try ExpertCardCodec.read(data).get(), card)
        XCTAssertEqual(ExpertInviteCodec.answeredInvite(in: data), "invite-1234")
        XCTAssertFalse(ExpertInviteCodec.isInvite(data))
    }

    func testAPlainCardAnswersNothing() {
        let card = ExpertCard(cardId: "card-1", name: "Sam Ferreira", phone: "+64 21 555 0100")
        XCTAssertEqual(ExpertInviteCodec.cardFileData(card, answering: nil), ExpertCardCodec.fileData(card))
        XCTAssertNil(ExpertInviteCodec.answeredInvite(in: ExpertCardCodec.fileData(card)))
    }

    func testAnAnsweringIdThisAppDoesntWriteIsIgnored() {
        let json = #"{"type":"openglasses.expert-card","version":1,"id":"card-1","name":"Sam","answeringInvite":"rm -rf"}"#
        XCTAssertNil(ExpertInviteCodec.answeredInvite(in: Data(json.utf8)))
    }
}
