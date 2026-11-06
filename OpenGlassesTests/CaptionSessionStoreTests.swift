import XCTest
@testable import OpenGlasses

/// Plan KP P5 — kept caption sessions: written only when asked, never in Medical Compliance mode,
/// gone after seven days, cleared at once by Delete all, and reached by the subject erasure.
///
/// Every store here is a fresh instance over a temporary directory with an injected clock and
/// injected switches; nothing touches the wearer's own sessions.
@MainActor
final class CaptionSessionStoreTests: XCTestCase {

    private var workspace: URL!
    private var clock = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33 UTC
    private var enabled = true
    private var compliance = false
    private var savedHIPAA: Any?
    private var savedKeep: Any?

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionSessionStoreTests_\(UUID().uuidString)", isDirectory: true)
        savedHIPAA = UserDefaults.standard.object(forKey: "hipaaMode")
        savedKeep = UserDefaults.standard.object(forKey: Config.keepCaptionSessionsKey)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        restore("hipaaMode", savedHIPAA)
        restore(Config.keepCaptionSessionsKey, savedKeep)
        super.tearDown()
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func makeStore() -> CaptionSessionStore {
        CaptionSessionStore(directory: workspace, now: { [unowned self] in clock },
                            isEnabled: { [unowned self] in enabled },
                            hipaaMode: { [unowned self] in compliance })
    }

    private func session(startedAt: Date, lines: [String] = ["Morning, how's the unit?"],
                         speaker: String? = nil, translation: String? = nil) -> CaptionSession {
        let turns = lines.enumerated().map { index, said in
            CaptionSession.Turn(at: startedAt.addingTimeInterval(Double(index) * 30), said: said,
                                translation: translation, speaker: speaker)
        }
        return CaptionSession(id: UUID(), startedAt: startedAt,
                              endedAt: startedAt.addingTimeInterval(600), turns: turns)
    }

    private func sessionFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []).sorted()
    }

    // MARK: - Round trip

    func testAKeptSessionReadsBackAsItWasWrittenAfterARelaunch() throws {
        let kept = session(startedAt: clock.addingTimeInterval(-3600),
                           lines: ["¿Dónde está el filtro?", "Debajo del panel."],
                           speaker: "Ana", translation: "Where is the filter?")
        XCTAssertEqual(makeStore().keep(kept), .kept)

        let reopened = makeStore()
        XCTAssertEqual(reopened.sessions, [kept])
        XCTAssertEqual(reopened.session(id: kept.id)?.turns.first?.speaker, "Ana")
        XCTAssertEqual(reopened.session(id: kept.id)?.turns.first?.translation, "Where is the filter?")
    }

    func testTheFileIsNamedByWhenTheSessionBegan() throws {
        let began = Date(timeIntervalSince1970: 1_792_990_000.25)
        _ = makeStore().keep(session(startedAt: began))
        XCTAssertEqual(sessionFiles(), [CaptionSessionStore.fileName(startedAt: began)])
        XCTAssertEqual(CaptionSessionStore.fileName(startedAt: began),
                       "caption-session-20261026T044640.250Z.json")
        XCTAssertEqual(CaptionSessionStore.startDate(fromFileName: sessionFiles()[0])?
                        .timeIntervalSince1970 ?? 0, began.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTwoSessionsThatBeganTogetherAreBothKept() {
        let store = makeStore()
        let began = clock.addingTimeInterval(-60)
        _ = store.keep(session(startedAt: began, lines: ["first"]))
        _ = store.keep(session(startedAt: began, lines: ["second"]))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(sessionFiles().count, 2)
    }

    func testTheListIsNewestFirst() {
        let store = makeStore()
        _ = store.keep(session(startedAt: clock.addingTimeInterval(-7200), lines: ["older"]))
        _ = store.keep(session(startedAt: clock.addingTimeInterval(-60), lines: ["newer"]))
        XCTAssertEqual(store.sessions.map { $0.turns[0].said }, ["newer", "older"])
    }

    // MARK: - Only when asked

    func testNothingIsWrittenWhenTheSettingIsOff() {
        enabled = false
        let store = makeStore()
        XCTAssertEqual(store.keep(session(startedAt: clock)), .settingOff)
        XCTAssertTrue(sessionFiles().isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testNothingIsWrittenInMedicalComplianceModeEvenWithTheSettingOn() {
        compliance = true
        enabled = true
        let store = makeStore()
        XCTAssertEqual(store.keep(session(startedAt: clock)), .complianceMode)
        XCTAssertTrue(sessionFiles().isEmpty)
    }

    func testASessionWithNothingSaidIsNotKept() {
        let empty = CaptionSession(id: UUID(), startedAt: clock, endedAt: clock, turns: [])
        XCTAssertEqual(makeStore().keep(empty), .empty)
        XCTAssertTrue(sessionFiles().isEmpty)
    }

    func testTheSettingIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: Config.keepCaptionSessionsKey)
        UserDefaults.standard.set(false, forKey: "hipaaMode")
        XCTAssertFalse(Config.keepCaptionSessions)
    }

    func testTheSettingCannotBeTurnedOnInMedicalComplianceMode() {
        UserDefaults.standard.set(true, forKey: "hipaaMode")
        XCTAssertFalse(Config.setKeepCaptionSessions(true), "the switch is refused in the mode")
        XCTAssertFalse(Config.keepCaptionSessions)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Config.keepCaptionSessionsKey))

        // A choice made before the mode does not read as on while it lasts.
        UserDefaults.standard.set(true, forKey: Config.keepCaptionSessionsKey)
        XCTAssertFalse(Config.keepCaptionSessions)

        UserDefaults.standard.set(false, forKey: "hipaaMode")
        XCTAssertTrue(Config.setKeepCaptionSessions(true))
        XCTAssertTrue(Config.keepCaptionSessions)
    }

    /// The production default switches, read through `Config`: nothing is written in the mode.
    func testTheDefaultSwitchesWriteNothingInMedicalComplianceMode() {
        UserDefaults.standard.set(true, forKey: Config.keepCaptionSessionsKey)
        UserDefaults.standard.set(true, forKey: "hipaaMode")
        let store = CaptionSessionStore(directory: workspace, now: { [unowned self] in clock })
        XCTAssertEqual(store.keep(session(startedAt: clock)), .complianceMode)
        XCTAssertTrue(sessionFiles().isEmpty)
    }

    func testTurningMedicalComplianceModeOnTurnsTheSettingOffForGood() {
        UserDefaults.standard.set(false, forKey: "hipaaMode")
        Config.setKeepCaptionSessions(true)
        let service = HIPAAComplianceService(store: MemoryAuditLogStore(),
                                             checkpoints: InMemoryAuditCheckpointStore())
        service.setMode(true)
        XCTAssertFalse(Config.keepCaptionSessions)
        service.setMode(false)
        XCTAssertFalse(Config.keepCaptionSessions, "it stays off until the wearer turns it on again")
    }

    // MARK: - Seven days

    func testASessionGoesSevenDaysAfterItBegan() {
        let store = makeStore()
        _ = store.keep(session(startedAt: clock, lines: ["kept"]))
        XCTAssertEqual(store.sessions.count, 1)

        clock = clock.addingTimeInterval(7 * 86_400 - 1)
        XCTAssertEqual(store.pruneExpired(), 0, "a second short of seven days, it stays")
        XCTAssertEqual(store.sessions.count, 1)

        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(store.pruneExpired(), 1)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(sessionFiles().isEmpty)
    }

    func testOpeningTheStorePrunesAnExpiredSession() {
        _ = makeStore().keep(session(startedAt: clock))
        clock = clock.addingTimeInterval(8 * 86_400)
        let reopened = makeStore()
        XCTAssertTrue(reopened.sessions.isEmpty)
        XCTAssertTrue(sessionFiles().isEmpty)
    }

    func testWritingPrunesAnExpiredSession() {
        let store = makeStore()
        _ = store.keep(session(startedAt: clock, lines: ["old"]))
        clock = clock.addingTimeInterval(7 * 86_400)
        _ = store.keep(session(startedAt: clock, lines: ["new"]))
        XCTAssertEqual(store.sessions.map { $0.turns[0].said }, ["new"])
        XCTAssertEqual(sessionFiles().count, 1)
    }

    /// The name carries the date, so an old session goes even when its words cannot be read (the
    /// phone not yet unlocked since it started).
    func testExpiryWorksFromTheFileNameWhenTheContentCannotBeRead() throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let old = clock.addingTimeInterval(-8 * 86_400)
        let url = workspace.appendingPathComponent(CaptionSessionStore.fileName(startedAt: old))
        try Data("not json".utf8).write(to: url)
        let store = makeStore()   // opening the store is a prune
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - Deleting

    func testDeleteAllClearsEverySession() {
        let store = makeStore()
        _ = store.keep(session(startedAt: clock.addingTimeInterval(-100)))
        _ = store.keep(session(startedAt: clock.addingTimeInterval(-50)))
        store.deleteAll()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(sessionFiles().isEmpty)
        XCTAssertTrue(makeStore().sessions.isEmpty)
    }

    func testDeletingOneSessionLeavesTheOthers() {
        let store = makeStore()
        let first = session(startedAt: clock.addingTimeInterval(-100), lines: ["one"])
        let second = session(startedAt: clock.addingTimeInterval(-50), lines: ["two"])
        _ = store.keep(first)
        _ = store.keep(second)
        store.delete(id: first.id)
        XCTAssertEqual(store.sessions, [second])
        XCTAssertEqual(makeStore().sessions, [second])
    }

    // MARK: - Erasure

    func testTheSubjectErasureRemovesEverySessionThatMentionsThePerson() async {
        let store = makeStore()
        let saidIt = session(startedAt: clock.addingTimeInterval(-300), lines: ["Ask Zylkorath about it"])
        let namedSpeaker = session(startedAt: clock.addingTimeInterval(-200), lines: ["Fine"],
                                   speaker: "Zylkorath")
        let inTranslation = session(startedAt: clock.addingTimeInterval(-150), lines: ["Hola"],
                                    translation: "Hello Zylkorath")
        let unrelated = session(startedAt: clock.addingTimeInterval(-100), lines: ["The coil is iced"])
        [saidIt, namedSpeaker, inTranslation, unrelated].forEach { _ = store.keep($0) }

        var stores = SubjectErasureCoordinator.Stores()
        stores.captionSessions = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("zylkorath"))

        let receipt = receipts.first { $0.store == .captionSessions }
        XCTAssertEqual(receipt?.localComplete, true)
        XCTAssertEqual(receipt?.removed, 3)
        XCTAssertEqual(makeStore().sessions, [unrelated])
    }

    func testTheErasureWalkAccountsForTheStoreWhenNoneIsSupplied() async {
        let receipts = await SubjectErasureCoordinator(stores: .init()).erase(.person("Anyone"))
        let receipt = receipts.first { $0.store == .captionSessions }
        XCTAssertNotNil(receipt?.unsupported)
        XCTAssertEqual(receipt?.localComplete, false)
    }

    // MARK: - Registry

    func testTheStoreIsRegisteredAsThirdPartyDataTheErasureWalks() {
        let record = SensitiveStore.captionSessions.record
        XCTAssertEqual(record.subjectLinkage, .thirdPartySubject)
        XCTAssertEqual(record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(CaptionSessionStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(record.backupExcluded)
        XCTAssertEqual(record.deleteAll, .api("CaptionSessionStore.deleteAll()"))
        XCTAssertEqual(record.deleteSubject, .api("CaptionSessionStore.deleteMatching(_:)"))
        XCTAssertTrue(SensitiveStore.registeredPaths
            .contains("OpenGlasses/Sources/Services/CaptionSessions/CaptionSessionStore.swift"))
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.captionSessions))
        XCTAssertEqual(AIFeature.ambientCaptions.record.stores, [.captionSessions])
    }

    func testAKeptFileIsOutOfBackup() throws {
        let kept = session(startedAt: clock)
        let store = makeStore()
        _ = store.keep(kept)
        let url = try XCTUnwrap(store.fileURL(for: kept))
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try workspace.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
