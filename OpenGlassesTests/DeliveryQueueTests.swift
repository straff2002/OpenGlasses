import XCTest
@testable import OpenGlasses

/// The delivery queue and the spoken send (Plan FO §6, P3b).
///
/// The one thing every test here is about: **nothing goes without the technician's say-so, and
/// nothing they asked for is quietly lost.** The partition between the two, the recipient order,
/// the refusal for a spoken address and the queue's own durability are each provable without a
/// car, a composer or a network.
@MainActor
final class DeliveryQueueTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryQueue-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entry(_ job: String, channel: DeliveryChannel = .email,
                       kind: QueuedSend.DocumentKind = .report,
                       state: QueuedSend.State = .staged,
                       secondsAgo: TimeInterval = 0) -> QueuedSend {
        QueuedSend(sessionId: "s-\(job)", jobNumber: "Job \(job)", documentKind: kind,
                   channel: channel, recipients: ["office@example.com"],
                   recipientSource: .deliverySettings,
                   createdAt: Date(timeIntervalSinceNow: -secondsAgo), state: state)
    }

    // MARK: - The channel partition

    func testOnlyTheUnattendedChannelGoesWithoutAScreen() {
        XCTAssertEqual(SpokenSendPolicy.handling(for: .endpoint), .immediate)
        for channel: DeliveryChannel in [.email, .messages, .whatsapp, .telegram, .shareSheet] {
            XCTAssertEqual(SpokenSendPolicy.handling(for: channel), .staged,
                           "\(channel.rawValue) needs the phone and must never send from the car")
        }
    }

    func testEveryStagedChannelSaysWhyItIsStaged() {
        for channel: DeliveryChannel in [.email, .messages, .whatsapp, .telegram, .shareSheet] {
            XCTAssertFalse(SpokenSendPolicy.stagingReason(for: channel).isEmpty,
                           "\(channel.rawValue) must explain itself")
        }
    }

    // MARK: - Recipients

    private var configured: DeliverySettings {
        DeliverySettings(emailRecipients: ["office@example.com"],
                         messageRecipients: ["+64211234567"])
    }

    func testThePreviousDeliveryWinsOverTheDeviceSettings() {
        let outcome = SpokenSendPolicy.recipients(channel: .email,
                                                  previousDelivery: ["dispatch@example.com"],
                                                  settings: configured)
        XCTAssertEqual(outcome, .resolved(["dispatch@example.com"], .previousDelivery))
    }

    func testTheDeviceSettingsComeBeforeTheOrganisationProfile() {
        let outcome = SpokenSendPolicy.recipients(channel: .email, settings: configured,
                                                  organisation: ["hq@example.com"])
        XCTAssertEqual(outcome, .resolved(["office@example.com"], .deliverySettings))
    }

    func testTheOrganisationProfileIsTheLastResort() {
        let outcome = SpokenSendPolicy.recipients(channel: .email, settings: DeliverySettings(),
                                                  organisation: ["hq@example.com"])
        XCTAssertEqual(outcome, .resolved(["hq@example.com"], .organisationProfile))
    }

    func testAChannelThatAddressesItselfNeedsNobody() {
        XCTAssertEqual(SpokenSendPolicy.recipients(channel: .endpoint, settings: DeliverySettings()),
                       .resolved([], .channelOwned))
    }

    /// The rule §6 states plainly, and the one mistake nobody would notice until the wrong person
    /// had the customer's job record.
    func testASpokenAddressIsRefusedAndNothingIsResolved() {
        let outcome = SpokenSendPolicy.recipients(channel: .email, settings: configured,
                                                  spokenAddress: "dave@example.com")
        XCTAssertEqual(outcome, .refused(SpokenSendPolicy.spokenAddressRefusal))
        XCTAssertTrue(SpokenSendPolicy.spokenAddressRefusal.contains("on the phone"))
    }

    func testASpelledOutAddressIsAlsoRefused() {
        let heard = "send it to dave at example dot com"
        XCTAssertNotNil(SpokenSendPolicy.spokenAddress(in: heard))
        XCTAssertNil(SpokenSendPolicy.spokenAddress(in: "send the job report"))
    }

    func testNobodyConfiguredIsARefusalThatSaysWhatToDo() {
        guard case .refused(let reason) = SpokenSendPolicy.recipients(
            channel: .email, settings: DeliverySettings()) else {
            return XCTFail("with nobody set up there is nowhere to send it")
        }
        XCTAssertTrue(reason.contains("Field Assist"))
    }

    // MARK: - What is said

    func testTheConfirmationNamesTheDocumentTheJobTheChannelAndWho() {
        let line = SpokenSendPolicy.confirmation(jobNumber: "Job 1005", documentKind: .report,
                                                 channel: .email,
                                                 recipients: ["base@example.com"],
                                                 includesDebrief: true)
        XCTAssertTrue(line.hasPrefix("The work order for job 1005"))
        XCTAssertTrue(line.contains("with the debrief"))
        XCTAssertTrue(line.contains("by email to base@example.com"))
        XCTAssertTrue(line.contains("send it"), "the technician has to be told what sends it")
        XCTAssertTrue(line.contains("one tap when you stop"))
    }

    func testAnImmediateChannelSaysItGoes() {
        let line = SpokenSendPolicy.confirmation(jobNumber: "Job 1005", documentKind: .addendum,
                                                 channel: .endpoint, recipients: [])
        XCTAssertTrue(line.hasPrefix("The debrief addendum for job 1005"))
        XCTAssertTrue(line.contains("and it goes"))
        XCTAssertFalse(line.contains("one tap"))
    }

    func testTheOutcomeDistinguishesGoneFromQueuedOffline() {
        XCTAssertTrue(SpokenSendPolicy.outcome(jobNumber: "Job 1005", documentKind: .report,
                                                channel: .endpoint, handled: .immediate)
                        .contains("has gone"))
        XCTAssertTrue(SpokenSendPolicy.outcome(jobNumber: "Job 1005", documentKind: .report,
                                                channel: .endpoint, handled: .immediate,
                                                queuedOffline: true)
                        .contains("queued"))
        XCTAssertEqual(SpokenSendPolicy.outcome(jobNumber: "Job 1005", documentKind: .report,
                                                channel: .email, handled: .staged),
                       "Ready on your phone — one tap when you stop.")
    }

    func testOnlySendItSends() {
        XCTAssertTrue(SpokenSendPolicy.isSendConfirmation("send it"))
        XCTAssertTrue(SpokenSendPolicy.isSendConfirmation("yes send it"))
        XCTAssertFalse(SpokenSendPolicy.isSendConfirmation("I'll send it later"))
        XCTAssertFalse(SpokenSendPolicy.isSendConfirmation("don't send it"))
        XCTAssertFalse(SpokenSendPolicy.isSendConfirmation("what did you find"))
    }

    func testTheQueueQuestionIsRecognised() {
        XCTAssertTrue(SpokenSendPolicy.isQueueQuery("what's waiting?"))
        XCTAssertTrue(SpokenSendPolicy.isQueueQuery("anything waiting"))
        XCTAssertFalse(SpokenSendPolicy.isQueueQuery("what's the superheat"))
    }

    // MARK: - The queue itself

    func testEntriesComeBackOldestFirstWhateverOrderTheyWereAdded() {
        var queue = DeliveryQueue()
        queue.append(entry("1006", secondsAgo: 10))
        queue.append(entry("1005", secondsAgo: 60))
        queue.append(entry("1007", secondsAgo: 1))
        XCTAssertEqual(queue.staged.map(\.jobNumber), ["Job 1005", "Job 1006", "Job 1007"])
    }

    func testCancellingOneKeepsTheOthers() {
        var queue = DeliveryQueue()
        let first = entry("1005", secondsAgo: 30)
        let second = entry("1006", secondsAgo: 20)
        queue.append(first)
        queue.append(second)
        queue.cancel(id: first.id)
        XCTAssertEqual(queue.staged.map(\.id), [second.id])
        XCTAssertEqual(queue.entry(id: first.id)?.state, .cancelled)
    }

    func testACancelledEntryStaysCancelled() {
        var queue = DeliveryQueue()
        let only = entry("1005")
        queue.append(only)
        queue.cancel(id: only.id)
        queue.update(id: only.id, to: .sent)
        XCTAssertEqual(queue.entry(id: only.id)?.state, .cancelled,
                       "a technician who said no is not overruled by a late composer callback")
    }

    func testTheCardHeadlineCountsOnlyWhatIsWaitingForAThumb() {
        var queue = DeliveryQueue()
        XCTAssertNil(queue.cardHeadline)
        queue.append(entry("1005"))
        XCTAssertEqual(queue.cardHeadline, "1 report ready to send")
        queue.append(entry("1006"))
        queue.append(entry("1007"))
        XCTAssertEqual(queue.cardHeadline, "3 reports ready to send")
        queue.append(entry("1008", channel: .endpoint, state: .sent))
        XCTAssertEqual(queue.cardHeadline, "3 reports ready to send")
    }

    func testTheReadBackNamesEachWaitingReportAndSaysTheyNeedThePhone() {
        var queue = DeliveryQueue()
        queue.append(entry("1005", secondsAgo: 30))
        queue.append(entry("1006", kind: .addendum, secondsAgo: 10))
        let spoken = queue.spokenReadBack
        XCTAssertTrue(spoken.hasPrefix("2 reports are ready to send."))
        XCTAssertTrue(spoken.contains("Job 1005"))
        XCTAssertTrue(spoken.contains("The debrief addendum for Job 1006"))
        XCTAssertTrue(spoken.contains("one tap each on the phone"))
    }

    func testNothingWaitingSaysSo() {
        XCTAssertEqual(DeliveryQueue().spokenReadBack, "Nothing's waiting to send.")
        var queue = DeliveryQueue()
        queue.append(entry("1005", channel: .endpoint, state: .sent))
        XCTAssertTrue(queue.spokenReadBack.contains("Everything you asked for has gone"))
    }

    // MARK: - Durability

    func testTheQueueSurvivesARestart() {
        let store = DeliveryQueueStore(directory: directory)
        store.append(entry("1005", secondsAgo: 30))
        store.append(entry("1006", secondsAgo: 10))
        XCTAssertEqual(store.queue.stagedCount, 2)

        // Everything a cold launch rebuilds, from the same directory.
        let reopened = DeliveryQueueStore(directory: directory)
        XCTAssertEqual(reopened.queue.staged.map(\.jobNumber), ["Job 1005", "Job 1006"])
        XCTAssertEqual(reopened.queue.staged.first?.recipients, ["office@example.com"])
    }

    func testACancelSurvivesARestartToo() {
        let store = DeliveryQueueStore(directory: directory)
        let doomed = entry("1005")
        store.append(doomed)
        store.append(entry("1006"))
        store.cancel(id: doomed.id)

        let reopened = DeliveryQueueStore(directory: directory)
        XCTAssertEqual(reopened.queue.stagedCount, 1)
        XCTAssertEqual(reopened.queue.entry(id: doomed.id)?.state, .cancelled)
    }

    /// A reset starts from no queue at all — which is the state a phone is in before anything is
    /// ever staged, and the state the UI-test seed says it writes.
    ///
    /// What this actually pins is that the eraser and the store agree on *which file*. A reset
    /// naming a path the store does not read would erase nothing and report nothing, and the queue
    /// would quietly carry every earlier launch's reports into the next one.
    func testErasingTheStoredQueueLeavesAColdLaunchWithNothingWaiting() {
        let store = DeliveryQueueStore(directory: directory)
        store.append(entry("1005"))
        store.append(entry("1006"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DeliveryQueueStore.fileURL(in: directory).path),
                      "the store and the eraser must name the same file")

        DeliveryQueueStore.eraseStoredQueue(in: directory)

        let reopened = DeliveryQueueStore(directory: directory)
        XCTAssertEqual(reopened.queue.stagedCount, 0)
        XCTAssertNil(reopened.queue.cardHeadline, "an erased queue draws no card at all")
    }

    /// Backup exclusion is checked on the file itself; the data-protection class is checked on the
    /// registry's claim, because a simulator has no data protection to read back — the attribute
    /// comes back nil there whatever the writer asked for.
    func testTheStoredFileIsNotBackedUp() throws {
        let store = DeliveryQueueStore(directory: directory)
        store.append(entry("1005"))
        let url = directory.appendingPathComponent("delivery-queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                        .isExcludedFromBackup, true,
                       "a queue restored onto another phone would offer to re-send a report")
    }

    func testTheStoreIsRegisteredAsASensitiveStore() {
        let record = SensitiveStore.jobDeliveryQueue.record
        XCTAssertEqual(record.owner, "DeliveryQueueStore")
        XCTAssertEqual(record.protection, .complete)
        XCTAssertTrue(record.backupExcluded)
        XCTAssertTrue(record.deleteAll.isAvailable)
    }

    // MARK: - The service

    /// A spy for the two seams that matter: what was actually delivered, and what was merely put
    /// in front of somebody.
    private final class Spy {
        var delivered: [DeliveryRequest] = []
        var presented: [DeliveryRequest] = []
        var spoken: [String] = []
        var notified: [Int] = []
    }

    private func makeService(spy: Spy, settings: DeliverySettings,
                             outcome: DeliveryOutcome = .sent) -> JobSendService {
        let service = JobSendService(queue: DeliveryQueueStore(directory: directory))
        service.connect(.init(
            speak: { line in spy.spoken.append(line) },
            settings: { settings },
            organisationRecipients: { [] },
            previousChannel: { _ in nil },
            buildRequest: { sessionId, channel, recipients, _ in
                DeliveryRequest(channel: channel, recipients: recipients, subject: "s",
                                body: "b", shortBody: "s",
                                record: Self.stubRecord(sessionId: sessionId))
            },
            deliverImmediately: { request in
                spy.delivered.append(request)
                return outcome
            },
            presentComposer: { request in spy.presented.append(request) },
            notify: { count in spy.notified.append(count) },
            log: { _, _, _ in }))
        return service
    }

    private static func stubRecord(sessionId: String) -> WorkRecord {
        var session = FieldSession(id: sessionId, vaultId: "refrigeration", assetId: nil,
                                   mode: .aiOnly, startedAt: Date(), outcome: .resolved,
                                   escalations: [], billableSeconds: 60)
        session.endedAt = Date()
        session.jobReference = "1005"
        return WorkRecord(session: session, vaultName: "Refrigeration")
    }

    func testAnImmediateChannelSendsThroughTheSinkAndSaysSo() async {
        let spy = Spy()
        let service = makeService(spy: spy,
                                  settings: DeliverySettings(endpoint: "https://example.com/jobs",
                                                             allowedChannels: [.endpoint]))
        _ = service.propose(sessionId: "s1", jobNumber: "Job 1005")
        XCTAssertNotNil(service.proposal)
        let said = await service.confirm()

        XCTAssertEqual(spy.delivered.count, 1, "the endpoint route actually delivers")
        XCTAssertTrue(spy.presented.isEmpty, "nothing was put in front of anybody")
        XCTAssertTrue(said.contains("has gone"))
        XCTAssertEqual(service.stagedCount, 0)
    }

    /// The assertion §6 turns on: Mail prepares and **never** sends.
    func testMailStagesAndTheDeliverySeamRecordsZeroSends() async {
        let spy = Spy()
        let service = makeService(spy: spy, settings: configured)
        _ = service.propose(sessionId: "s1", jobNumber: "Job 1005")
        let said = await service.confirm()

        XCTAssertTrue(spy.delivered.isEmpty, "a staged send must not reach the delivery route")
        XCTAssertTrue(spy.presented.isEmpty, "and must not open a composer on its own either")
        XCTAssertEqual(said, "Ready on your phone — one tap when you stop.")
        XCTAssertEqual(service.stagedCount, 1)
        XCTAssertEqual(spy.notified, [1], "the phone is told once, with the count")
    }

    func testASpokenAddressIsRefusedBeforeAnythingIsQueued() async {
        let spy = Spy()
        let service = makeService(spy: spy, settings: configured)
        let said = service.propose(sessionId: "s1", jobNumber: "Job 1005",
                                   utterance: "send it to dave@example.com")
        XCTAssertEqual(said, SpokenSendPolicy.spokenAddressRefusal)
        XCTAssertNil(service.proposal, "a refusal leaves nothing a later \"send it\" could complete")
        _ = await service.confirm()
        XCTAssertEqual(service.stagedCount, 0)
        XCTAssertTrue(spy.delivered.isEmpty)
    }

    func testSendAllOpensEachComposerInTurnAndACancelledOneStaysQueued() async {
        let spy = Spy()
        let service = makeService(spy: spy, settings: configured)
        for job in ["1005", "1006", "1007"] {
            _ = service.propose(sessionId: "s-\(job)", jobNumber: "Job \(job)")
            _ = await service.confirm()
        }
        XCTAssertEqual(service.stagedCount, 3)

        let walked = service.sendAll()
        XCTAssertEqual(walked.count, 3)
        XCTAssertEqual(spy.presented.count, 1, "one at a time")

        // The first is sent, the second cancelled, the third sent.
        service.completePresented(outcome: .sent)
        XCTAssertEqual(spy.presented.count, 2)
        service.completePresented(outcome: .cancelled)
        XCTAssertEqual(spy.presented.count, 3)
        service.completePresented(outcome: .sent)

        XCTAssertEqual(service.stagedCount, 1, "the cancelled one is still waiting")
        XCTAssertEqual(service.staged.first?.jobNumber, "Job 1006")
    }

    func testCancellingFromTheCardLeavesTheRest() async {
        let spy = Spy()
        let service = makeService(spy: spy, settings: configured)
        for job in ["1005", "1006"] {
            _ = service.propose(sessionId: "s-\(job)", jobNumber: "Job \(job)")
            _ = await service.confirm()
        }
        let doomed = try? XCTUnwrap(service.staged.first)
        service.cancel(id: doomed!.id)
        XCTAssertEqual(service.staged.map(\.jobNumber), ["Job 1006"])
    }

    func testAQueuedSendSurvivesARestartOfTheService() async {
        let spy = Spy()
        let service = makeService(spy: spy, settings: configured)
        _ = service.propose(sessionId: "s1", jobNumber: "Job 1005")
        _ = await service.confirm()

        let reopened = JobSendService(queue: DeliveryQueueStore(directory: directory))
        XCTAssertEqual(reopened.stagedCount, 1)
        XCTAssertEqual(reopened.cardHeadline, "1 report ready to send")
    }
}
