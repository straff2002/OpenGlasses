import XCTest
@testable import OpenGlasses

/// Plan KW §4: invites asking for the expert's card, held beside the handovers.
@MainActor
final class AssistingInviteStoreTests: XCTestCase {

    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssistingInvites-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> AssistingHandoverStore {
        AssistingHandoverStore(directory: directory, now: { [unowned self] in self.clock })
    }

    private func invite(_ id: String = "invite-1", org: String = "Northside Heating", by: String = "Pat Hale")
        -> ExpertInvite {
        ExpertInvite(inviteId: id, organisation: org, invitedBy: by, replyTo: "pat@example.test", created: clock)
    }

    func testAnInviteIsKeptAcrossARelaunch() {
        let store = makeStore()
        XCTAssertEqual(store.openInvite(invite()), .added)
        XCTAssertEqual(makeStore().invites.map(\.id), ["invite-1"])
    }

    func testTheSameInviteTwiceIsKeptOnce() {
        let store = makeStore()
        XCTAssertEqual(store.openInvite(invite()), .added)
        XCTAssertEqual(store.openInvite(invite()), .alreadyHeld)
        XCTAssertEqual(store.invites.count, 1)
    }

    func testAnExpiredInviteIsNotKept() {
        let store = makeStore()
        let old = invite()
        clock = old.expires
        XCTAssertEqual(store.openInvite(old), .expired)
        XCTAssertTrue(store.invites.isEmpty)
    }

    func testRetentionRemovesAnInviteThatRanOut() {
        let store = makeStore()
        let made = invite()
        _ = store.openInvite(made)
        XCTAssertEqual(store.purgeExpired(now: made.expires.addingTimeInterval(-1)), 0)
        XCTAssertEqual(store.purgeExpired(now: made.expires), 1)
        XCTAssertTrue(store.invites.isEmpty)
    }

    func testTheSubjectErasureFindsAnInviteByWhoSentIt() {
        let store = makeStore()
        _ = store.openInvite(invite("invite-1", by: "Pat Hale"))
        _ = store.openInvite(invite("invite-2", by: "Robin Grey"))
        XCTAssertEqual(store.deleteMatching("pat hale"), 1)
        XCTAssertEqual(store.invites.map(\.id), ["invite-2"])
    }

    func testRemoveAllTakesTheInvitesToo() {
        let store = makeStore()
        _ = store.openInvite(invite())
        store.removeAll()
        XCTAssertTrue(store.invites.isEmpty)
        XCTAssertTrue(makeStore().invites.isEmpty)
    }

    func testAnsweringOrDecliningRemovesIt() {
        let store = makeStore()
        _ = store.openInvite(invite())
        store.removeInvite(id: "invite-1")
        XCTAssertTrue(store.invites.isEmpty)
    }

    func testDismissingFromHomeKeepsItInAssisting() {
        let store = makeStore()
        _ = store.openInvite(invite())
        store.dismissInviteFromHome(id: "invite-1")
        XCTAssertEqual(store.invite(id: "invite-1")?.homeDismissed, true)
    }

    func testTheInvitesFileIsProtectedAndOutOfBackup() throws {
        let store = makeStore()
        _ = store.openInvite(invite())
        let values = try store.invitesLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - The service

    func testOpeningAnInviteMakesAssistingPresentAndShowsIt() throws {
        let service = AssistingService(store: makeStore(), cards: ExpertCardStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "kw-\(UUID().uuidString)"))),
                                       now: { [unowned self] in self.clock })
        XCTAssertFalse(service.presence.isPresent)
        XCTAssertNil(service.openInvite(ExpertInviteCodec.fileData(invite())))
        service.refreshPresence()
        XCTAssertTrue(service.presence.isPresent)
        XCTAssertEqual(service.presence.homeCard, .invite(inviteId: "invite-1", organisation: "Northside Heating"))
        XCTAssertEqual(service.presentedInvite?.id, "invite-1")
        XCTAssertEqual(service.feed.presence, service.presence, "the feed the hub reads says the same")
        XCTAssertFalse(service.feed === AssistingPresenceFeed.shared, "a test's service never draws the app's hub")

        service.answerInvite("invite-1")
        XCTAssertNil(service.presentedInvite)
        XCTAssertFalse(service.presence.isPresent)
    }

    func testARefusedInviteSaysWhy() throws {
        let service = AssistingService(store: makeStore(), cards: ExpertCardStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "kw-\(UUID().uuidString)"))),
                                       now: { [unowned self] in self.clock })
        let nobody = ExpertInvite(inviteId: "invite-1", organisation: "", invitedBy: "", replyTo: nil, created: clock)
        XCTAssertEqual(service.openInvite(ExpertInviteCodec.fileData(nobody)),
                       "That invite can't be used: it doesn't say who it's from.")
        XCTAssertFalse(service.presence.isPresent)
    }
}
