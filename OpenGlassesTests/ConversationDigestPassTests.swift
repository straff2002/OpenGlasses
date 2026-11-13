import XCTest
@testable import OpenGlasses

/// Plan LQ P1 — notes written and forgotten, against a real store in a temp directory and a fake
/// model. The conversations are invented.
@MainActor
final class ConversationDigestPassTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!
    private var calls: [ConversationDigestInput.Request] = []
    private var answer: (ConversationDigestInput.Request) throws -> ConversationDigestCompletion = { _ in
        ConversationDigestCompletion(
            draft: ConversationDigestDraft(headline: "Leaking kitchen tap: plumber on Thursday",
                                           points: [.init(kind: "decided", text: "Plumber on Thursday"),
                                                    .init(kind: "learned", text: "Washer size is 15 mm")]),
            finishedNormally: true)
    }
    /// Runs inside the model call, while the pass is waiting on it.
    private var whileAnswering: (() -> Void)?
    private var settings = ConversationDigestPass.Settings(
        orgPinnedOff: false, enabled: true, hipaaMode: false, provider: .anthropic,
        inForeground: true, atSpendCap: false, jobThreadIDs: [])
    private var savedDigestSetting: Any?

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lq-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        savedDigestSetting = UserDefaults.standard.object(forKey: "conversationDigestsEnabled")
        PolicyEnvelope.clear()
        store = ConversationStore(directory: directory)
        store.answerProvider = { LLMProvider.anthropic.rawValue }
        calls = []
        whileAnswering = nil
    }

    override func tearDown() async throws {
        store = nil
        PolicyEnvelope.clear()
        if let savedDigestSetting {
            UserDefaults.standard.set(savedDigestSetting, forKey: "conversationDigestsEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "conversationDigestsEnabled")
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try await super.tearDown()
    }

    private func makePass() -> ConversationDigestPass {
        ConversationDigestPass(store: store, summarise: { [unowned self] request in
            self.calls.append(request)
            self.whileAnswering?()
            return try self.answer(request)
        }, timeZone: { TimeZone(identifier: "UTC")! })
    }

    /// The leaking-tap conversation in the active thread.
    @discardableResult
    private func seedTap() -> String {
        let thread = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "The kitchen tap has been dripping since the weekend, what could it be?")
        store.appendMessage(role: "assistant", content: "Most often a worn washer, or the cartridge if it is a mixer.")
        store.appendMessage(role: "user", content: "What size washer would a standard tap take?")
        store.appendMessage(role: "assistant", content: "Usually 15 mm for a half-inch valve; check the old one first.")
        store.appendMessage(role: "user", content: "I'll call the plumber on Thursday then.")
        store.appendMessage(role: "assistant", content: "Good plan, mention it drips when closed.")
        return thread.id
    }

    private func digest(_ id: String) -> ConversationDigest? { store.threads.first { $0.id == id }?.digest }

    // MARK: - Written once, however the thread is left

    func testAReplyRecordsWhoAnsweredIt() {
        let id = seedTap()
        XCTAssertEqual(store.threads.first { $0.id == id }?.lastAnswerProvider, "anthropic")
        store.appendMessage(role: "assistant", content: "Offline fallback answer", answeredOnDevice: true)
        XCTAssertEqual(store.threads.first { $0.id == id }?.lastAnswerProvider,
                       ConversationStore.offlineAnswerProvider)
    }

    func testLeavingByEndingWritesOnce() async {
        let pass = makePass()
        store.onThreadLeft = { pass.enqueue($0) }
        let id = seedTap()
        store.endThread()
        XCTAssertEqual(pass.pending, [id])
        let reports = await pass.drain { self.settings }
        XCTAssertEqual(reports, [.written(points: 2, dropped: 0)])
        XCTAssertEqual(digest(id)?.headline, "Leaking kitchen tap: plumber on Thursday")
        XCTAssertEqual(digest(id)?.tier, .cloud)
        XCTAssertEqual(store.threads.first { $0.id == id }?.listSummary, "Leaking kitchen tap: plumber on Thursday")

        // Left again with nothing new said: no second call.
        _ = store.resumeThread(id)
        store.endThread()
        let again = await pass.drain { self.settings }
        XCTAssertEqual(again, [.ineligible(.upToDate)])
        XCTAssertEqual(calls.count, 1)
    }

    func testLeavingByReplacementWritesOnce() async {
        let pass = makePass()
        store.onThreadLeft = { pass.enqueue($0) }
        let id = seedTap()
        // The idle gap and a new conversation both start a thread over the open one.
        store.startThread(mode: "direct")
        XCTAssertEqual(pass.pending, [id], "a replaced thread is left too")
        _ = await pass.drain { self.settings }
        XCTAssertNotNil(digest(id))
        XCTAssertEqual(calls.count, 1)
    }

    func testAResumedConversationIsRewrittenOncePerNewTail() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        _ = await pass.run(threadID: id) { self.settings }
        _ = store.resumeThread(id)
        store.appendMessage(role: "user", content: "The plumber can't make Thursday.")
        store.appendMessage(role: "assistant", content: "Friday morning is the next opening.")
        store.endThread()
        answer = { request in
            XCTAssertTrue(request.user.contains("Leaking kitchen tap: plumber on Thursday"), "the old note is read")
            return ConversationDigestCompletion(
                draft: ConversationDigestDraft(headline: "Leaking kitchen tap: plumber moved to Friday", points: []),
                finishedNormally: true)
        }
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .written(points: 0, dropped: 0))
        XCTAssertEqual(digest(id)?.headline, "Leaking kitchen tap: plumber moved to Friday")
        let thirdTime = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(thirdTime, .ineligible(.upToDate))
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Nothing written, nothing sent

    func testHIPAAWritesNothingAndSendsNothing() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        settings.hipaaMode = true
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .skipped(.hipaaMode))
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(digest(id))
        XCTAssertNotNil(store.threads.first { $0.id == id }?.summary, "the word-prefix summary stays")
    }

    func testASwitchedProviderWritesNothing() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        settings.provider = .openai
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .skipped(.providerChanged))
        XCTAssertTrue(calls.isEmpty)
    }

    func testAJobThreadIsNeverSent() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        settings.jobThreadIDs = [id]
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .ineligible(.jobThread))
        XCTAssertTrue(calls.isEmpty)
    }

    func testANeighboursDiagnosisPointIsDroppedAndTheRestKept() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        answer = { _ in
            ConversationDigestCompletion(
                draft: ConversationDigestDraft(headline: "Kitchen tap and the weekend",
                                               points: [.init(kind: "learned", text: "Neighbour Sam has been diagnosed with diabetes"),
                                                        .init(kind: "decided", text: "Plumber on Thursday")]),
                finishedNormally: true)
        }
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .written(points: 1, dropped: 1))
        XCTAssertEqual(digest(id)?.points.map(\.text), ["Plumber on Thursday"])
    }

    func testAFailedCallBacksOffAndKeepsTheSummary() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        answer = { _ in throw ConversationDigestError.unavailable }
        let failed = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(failed, .failed("unavailable"))
        let next = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(next, .skipped(.backingOff))
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(digest(id))
    }

    // MARK: - Forgotten and erased

    func testAForgottenNoteIsNotRewrittenAfterAResume() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        _ = await pass.run(threadID: id) { self.settings }
        XCTAssertTrue(store.forgetDigest(threadId: id))
        XCTAssertEqual(digest(id)?.isRedacted, true)
        XCTAssertNotEqual(store.threads.first { $0.id == id }?.listSummary, "Leaking kitchen tap: plumber on Thursday",
                          "a forgotten note is not shown")

        _ = store.resumeThread(id)
        store.appendMessage(role: "user", content: "One more question about the tap washer size")
        store.appendMessage(role: "assistant", content: "15 mm, as before.")
        store.endThread()
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .ineligible(.redacted))
        XCTAssertEqual(calls.count, 1)

        // Reopened from disk, still forgotten.
        let reopened = ConversationStore(directory: directory)
        XCTAssertEqual(reopened.threads.first { $0.id == id }?.digest?.isRedacted, true)
    }

    func testPersonErasureClearsPointsNamingThem() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        answer = { _ in
            ConversationDigestCompletion(
                draft: ConversationDigestDraft(headline: "Kitchen tap repair",
                                               points: [.init(kind: "toDo", text: "Ask Priya for the plumber's number"),
                                                        .init(kind: "decided", text: "Plumber on Thursday")]),
                finishedNormally: true)
        }
        _ = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(store.dropDigestPoints(naming: "Priya"), 1)
        XCTAssertEqual(digest(id)?.points.map(\.text), ["Plumber on Thursday"])
        XCTAssertEqual(digest(id)?.headline, "Kitchen tap repair")

        XCTAssertEqual(store.dropDigestPoints(naming: "Kitchen"), 1, "a headline naming them clears the note")
        XCTAssertEqual(digest(id)?.isRedacted, true)
        XCTAssertEqual(store.dropDigestPoints(naming: "Thursday"), 0, "a forgotten note has nothing left to clear")
    }

    func testDeletingAThreadLeavesNoNoteAnywhere() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        _ = await pass.run(threadID: id) { self.settings }
        store.deleteThread(id)
        XCTAssertNil(store.threads.first { $0.id == id })
        let reopened = ConversationStore(directory: directory)
        XCTAssertFalse(reopened.threads.contains { $0.digest != nil })
    }

    func testAnEditThatRemovesWhatTheNoteCoversDropsIt() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        _ = await pass.run(threadID: id) { self.settings }
        let lastUser = store.threads.first { $0.id == id }!.messages.last { $0.role == "user" }!
        store.truncate(from: lastUser.id, in: id)
        XCTAssertNil(digest(id), "the note described words the wearer took back")
    }

    // MARK: - An organisation's pin

    private func pinNotesOff() {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30,
                                    settings: ["conversationDigestsEnabled": RawSetting(.bool(false), .ceiling)])
        PolicyEnvelope.install(ProfileApplier.apply(profile: profile, resolvableVaultIds: []),
                               organizationName: "Northbridge Mechanical")
    }

    func testTheKeyIsACeilingThatOnlyPinsOff() {
        XCTAssertEqual(SettingKey.conversationDigestsEnabled.kind, .ceiling(pinnedTo: false))
        XCTAssertEqual(SettingKey.conversationDigestsEnabled.rawValue, "conversationDigestsEnabled")
        XCTAssertEqual(SettingKey.conversationDigestsEnabled.ceilingDescription,
                       "Notes of finished conversations are off")
        XCTAssertTrue(SettingsVisibilityPolicy.alwaysShown.contains(.key(.conversationDigestsEnabled)),
                      "the switch shows as set by the organisation")
    }

    func testWithTheKeyPinnedOffNoCallIsMadeAndTheSetterIsRefused() async {
        UserDefaults.standard.set(true, forKey: "conversationDigestsEnabled")
        pinNotesOff()
        XCTAssertFalse(Config.conversationDigestsEnabled)
        Config.setConversationDigestsEnabled(true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "conversationDigestsEnabled") as? Bool, true,
                       "the wearer's own value is left alone")
        Config.setConversationDigestsEnabled(false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "conversationDigestsEnabled") as? Bool, true,
                       "the setter is refused while the key is locked")

        let pass = makePass()
        let id = seedTap()
        store.endThread()
        settings.orgPinnedOff = PolicyEnvelope.isLocked(.conversationDigestsEnabled)
        settings.enabled = Config.conversationDigestsEnabled
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .skipped(.orgPinnedOff))
        XCTAssertTrue(calls.isEmpty)

        PolicyEnvelope.clear()
        XCTAssertTrue(Config.conversationDigestsEnabled, "removing the profile puts back the wearer's choice")
    }

    func testACallInFlightWhenThePinArrivesSavesNothing() async {
        let pass = makePass()
        let id = seedTap()
        store.endThread()
        whileAnswering = { [unowned self] in
            self.pinNotesOff()
            self.settings.orgPinnedOff = true
        }
        let report = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(report, .saveRefused(.orgPinnedOff))
        XCTAssertEqual(calls.count, 1, "the call in flight finished")
        XCTAssertNil(digest(id))
    }

    func testTheStoreRefusesANoteWhilePinnedWhateverTheCallerSays() {
        let id = seedTap()
        let last = store.threads.first { $0.id == id }!.messages.last!.id
        pinNotesOff()
        let note = ConversationDigest(headline: "Tap", points: [], coversThroughMessageID: last,
                                      writtenAt: Date(), tier: .cloud)
        XCTAssertEqual(store.saveDigest(note, for: id), .orgPinnedOff)
        PolicyEnvelope.clear()
        XCTAssertEqual(store.saveDigest(note, for: id), .saved)
    }

    func testAPinStopsTheBacklogAndExistingNotesStay() async throws {
        let suite = "lq-backlog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ConversationDigestBacklogLedger(defaults: defaults)
        _ = ledger.since(now: Date().addingTimeInterval(-86_400))

        let pass = makePass()
        let written = seedTap()
        store.endThread()
        _ = await pass.run(threadID: written) { self.settings }
        let missed = seedTap()
        store.endThread()
        for index in store.threads.indices { store.threads[index].updatedAt = Date().addingTimeInterval(-3_600) }

        pinNotesOff()
        settings.orgPinnedOff = true
        let pinned = await pass.runBacklog(settings: { self.settings }, ledger: ledger)
        XCTAssertTrue(pinned.isEmpty)
        XCTAssertNil(digest(missed))
        XCTAssertNotNil(digest(written)?.visibleHeadline, "a pin never deletes a note (decision 9)")

        PolicyEnvelope.clear()
        settings.orgPinnedOff = false
        let reports = await pass.runBacklog(settings: { self.settings }, ledger: ledger)
        XCTAssertEqual(reports, [.written(points: 2, dropped: 0)])
        XCTAssertNotNil(digest(missed))
        XCTAssertEqual(ledger.used(), 1)
    }

    func testTheBacklogLeavesAnOnDeviceThreadForTheForeground() async throws {
        let suite = "lq-backlog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ConversationDigestBacklogLedger(defaults: defaults)
        _ = ledger.since(now: Date().addingTimeInterval(-86_400))
        store.answerProvider = { LLMProvider.appleOnDevice.rawValue }
        let id = seedTap()
        store.endThread()
        store.threads[0].updatedAt = Date().addingTimeInterval(-3_600)
        settings.provider = .appleOnDevice
        settings.inForeground = false

        let pass = makePass()
        let left = await pass.run(threadID: id) { self.settings }
        XCTAssertEqual(left, .deferred)
        XCTAssertTrue(calls.isEmpty)

        settings.inForeground = true
        let reports = await pass.runBacklog(settings: { self.settings }, ledger: ledger)
        XCTAssertEqual(reports, [.written(points: 2, dropped: 0)])
        XCTAssertEqual(digest(id)?.tier, .onDevice)
    }
}
