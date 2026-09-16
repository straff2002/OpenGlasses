import XCTest
@testable import OpenGlasses

/// Plan FE P4 — acknowledging result delivery accurately.
///
/// Every test here drives the real chain: a scripted speech outcome → `AgentSessionService` →
/// `CustomAgentHarness` → a fixture endpoint through the shared `URLProtocol` stub, asserting the
/// spoken line, the delivery record, **and how many requests the endpoint actually received**.
///
/// The defect being closed is a single sentence: `emit` spoke the summary through a closure
/// returning `Void`, so a result read out over a barge-in and a result the wearer heard were the
/// same event. Everything below is a consequence of that — what gets acknowledged, what gets
/// replayed, and what a relaunch is allowed to claim.
@MainActor
final class AgentResultDeliveryTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_757_100_000)
    private var savedAgentMode = false
    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        savedAgentMode = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
        suiteName = "AgentResultDeliveryTests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        defaultsSuite.removePersistentDomain(forName: suiteName)
        Config.setAgentModeEnabled(savedAgentMode)
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// An endpoint that asks to be told when a result has been read out.
    private func ackingConfig(host: String = "https://agent.test") -> CustomHarnessConfig {
        var config = CustomHarnessConfig()
        config.startURL = "\(host)/start"
        config.statusURLTemplate = "\(host)/runs/{id}"
        config.ackURLTemplate = "\(host)/runs/{id}/ack"
        config.authHeader = "Authorization"
        config.authValue = "Bearer tok"
        config.finalTextPath = "result.summary"
        return config
    }

    private func harness(_ config: CustomHarnessConfig) -> CustomAgentHarness {
        var harness = CustomAgentHarness(config: config, session: MockURLProtocol.session())
        harness.policy = AgentPollingPolicy(interval: 5, maxRetries: 2, baseBackoff: 1,
                                            maxBackoff: 4, maxUnknownStatusTicks: 3, maxAckRetries: 2)
        harness.sleeper = { _ in }
        return harness
    }

    private struct Rig {
        let service: AgentSessionService
        let spoken: Box<[String]>
        let store: AgentDeliveryRecordStore
    }

    /// A box so a closure can append without the test holding an inout.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A session with a live run, a scripted playback outcome and a record store of its own.
    ///
    /// `outcomes` is consumed in order; the last entry repeats — so a test can say "the first
    /// reading was cut off, the replay completed" without scripting each utterance.
    private func rig(_ config: CustomHarnessConfig,
                     outcomes: [SpeechDeliveryOutcome] = [.completed],
                     runID: String = "r1") -> Rig {
        let service = AgentSessionService()
        let spoken = Box<[String]>([])
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        let played = Box<Int>(0)

        service.now = { self.fixedNow }
        service.sleeper = { _ in }
        service.policy = AgentPollingPolicy(interval: 5, maxRetries: 2, baseBackoff: 1,
                                            maxBackoff: 4, maxUnknownStatusTicks: 3, maxAckRetries: 2)
        service.speak = { spoken.value.append($0) }
        service.speakResult = { line in
            spoken.value.append(line)
            let index = min(played.value, outcomes.count - 1)
            played.value += 1
            return outcomes[index]
        }
        service.deliveryStore = store
        service.setHarness(harness(config))
        service.handle(.started(AgentRun(id: runID, harness: .custom, prompt: "add a toggle",
                                         project: "my-app", status: .running, startedAt: fixedNow)))
        return Rig(service: service, spoken: spoken, store: store)
    }

    private func result(_ summary: String, files: [String] = []) -> AgentRunResult {
        var result = AgentRunResult()
        result.finalText = summary
        result.reported.insert(.finalText)
        if !files.isEmpty {
            result.filesCreated = files
            result.reported.insert(.filesCreated)
        }
        return result
    }

    private var ackRequests: [(request: URLRequest, body: Data?)] {
        MockURLProtocol.requests.filter { $0.request.url?.path.hasSuffix("/ack") == true }
    }

    private func ackBody(_ index: Int) -> [String: Any] {
        guard index < ackRequests.count, let body = ackRequests[index].body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return json
    }

    // MARK: - Completion

    func testCompletedDeliveryIsRecordedAndAckedOnceWithItsRevision() async {
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        let delivery = try? XCTUnwrap(rig.service.latestDelivery)
        XCTAssertEqual(delivery?.state, .completed)
        XCTAssertEqual(delivery?.resultRevision, 0)
        XCTAssertEqual(delivery?.ackState, .acknowledged)
        XCTAssertEqual(ackRequests.count, 1, "one delivery, one acknowledgement")
        XCTAssertEqual(ackBody(0)["resultRevision"] as? Int, 0)
        XCTAssertEqual(ackBody(0)["runId"] as? String, "r1")
        XCTAssertEqual(ackBody(0)["deliveryState"] as? String, "completed")
    }

    func testTheAckRidesTheEndpointsOwnURLAndCredential() async {
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Done.")))
        await rig.service.awaitDelivery()

        let request = try? XCTUnwrap(ackRequests.first?.request)
        XCTAssertEqual(request?.url?.absoluteString, "https://agent.test/runs/r1/ack")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testTheAckIdIsDerivedFromTheRunAndRevisionSoItSurvivesARelaunch() {
        let first = AgentDeliveryAck.id(runID: "r1", revision: 0)
        XCTAssertEqual(first, AgentDeliveryAck.id(runID: "r1", revision: 0))
        XCTAssertNotEqual(first, AgentDeliveryAck.id(runID: "r1", revision: 1))
        XCTAssertNotEqual(first, AgentDeliveryAck.id(runID: "r2", revision: 0))
    }

    func testAStatusLineClaimsNothingExtraWhenTheWearerHeardIt() async {
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()
        XCTAssertFalse(rig.service.currentStatusLine().contains("replay"),
                       "a completed reading is not something to offer again unprompted")
    }

    // MARK: - Interruption

    func testBargeInMidSummaryIsInterruptedAndNotAcked() async {
        let rig = rig(ackingConfig(), outcomes: [.interrupted(by: .bargeIn)])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.latestDelivery?.state, .interrupted)
        XCTAssertEqual(rig.service.latestDelivery?.ackState,
                       .unacknowledged(reason: .notCompleted))
        XCTAssertEqual(ackRequests.count, 0,
                       "acknowledging a result that was talked over would tell the endpoint to stop resending it")
    }

    func testAnInterruptedResultOffersAReplayInTheStatusLine() async {
        let rig = rig(ackingConfig(), outcomes: [.interrupted(by: .bargeIn)])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()
        XCTAssertTrue(rig.service.currentStatusLine().contains("say replay"))
    }

    func testReplayAfterBargeInSpeaksTheMissedResultAndMarksItCompleted() async {
        let rig = rig(ackingConfig(), outcomes: [.interrupted(by: .bargeIn), .completed])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        let line = await rig.service.replayLastResult()
        XCTAssertTrue(line.hasPrefix(AgentDeliveryPhrasing.missedPrefix), "spoken: \(line)")
        XCTAssertTrue(line.contains("toggle"))
        XCTAssertEqual(rig.service.latestDelivery?.state, .completed)
        XCTAssertEqual(rig.service.latestDelivery?.ackState, .acknowledged)
        XCTAssertEqual(ackRequests.count, 1, "the ack waited for a delivery that actually landed")
        XCTAssertEqual(rig.service.deliveries.count, 1,
                       "a replay is the same revision delivered again, not a new result")
    }

    func testAReplayOfAResultAlreadyHeardDoesNotClaimTheyMissedIt() async {
        let rig = rig(ackingConfig(), outcomes: [.completed])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        let line = await rig.service.replayLastResult()
        XCTAssertTrue(line.hasPrefix(AgentDeliveryPhrasing.againPrefix), "spoken: \(line)")
        XCTAssertEqual(ackRequests.count, 1, "an already-acknowledged revision is not acknowledged twice")
    }

    func testReplayWithNothingRetainedSaysSo() async {
        let rig = rig(ackingConfig())
        let line = await rig.service.replayLastResult()
        XCTAssertEqual(line, AgentDeliveryPhrasing.nothingToReplay)
        XCTAssertEqual(ackRequests.count, 0)
    }

    // MARK: - Suppression

    func testANoRouteResultIsSuppressedNotAckedAndOfferedForReplay() async {
        let rig = rig(ackingConfig(), outcomes: [.suppressed(reason: .noRoute)])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.latestDelivery?.state, .suppressed)
        XCTAssertEqual(ackRequests.count, 0)
        XCTAssertTrue(rig.service.currentStatusLine().contains("say replay"))
        XCTAssertTrue(rig.service.canReplayResult)
    }

    func testAMutedResultIsSuppressedAndReplayable() async {
        let rig = rig(ackingConfig(), outcomes: [.suppressed(reason: .muted), .completed])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()
        XCTAssertEqual(rig.service.latestDelivery?.state, .suppressed)

        let line = await rig.service.replayLastResult()
        XCTAssertTrue(line.hasPrefix(AgentDeliveryPhrasing.missedPrefix))
        XCTAssertEqual(ackRequests.count, 1)
    }

    // MARK: - Failure

    func testAnEngineFailureIsRecordedAsFailedAndNotAcked() async {
        let rig = rig(ackingConfig(), outcomes: [.failed(reason: "no engine")])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.latestDelivery?.state, .failed)
        XCTAssertEqual(ackRequests.count, 0)
        XCTAssertTrue(rig.service.currentStatusLine().contains("say replay"),
                      "a result nothing could read out is still owed to the wearer")
    }

    // MARK: - Revisions and dedupe

    func testDuplicateTerminalReportsDeliverOnce() async {
        let rig = rig(ackingConfig())
        let reported = result("Added the toggle.", files: ["Sources/Toggle.swift"])
        rig.service.handle(.completed(reported))
        await rig.service.awaitDelivery()
        rig.service.handle(.completed(reported))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.deliveries.count, 1,
                       "an endpoint repeating itself is one result, not two")
        XCTAssertEqual(ackRequests.count, 1)
        let summary = rig.service.lastSummary ?? ""
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(rig.spoken.value.filter { $0 == summary }.count, 1,
                       "and it is read out once")
    }

    func testARevisedResultGetsANewRevisionDeliveredAndAckedSeparately() async {
        let rig = rig(ackingConfig(), outcomes: [.completed])
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()
        // The endpoint reports again, now naming a file it changed.
        rig.service.handle(.completed(result("Added the toggle.", files: ["Sources/Toggle.swift"])))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.deliveries.map(\.resultRevision), [0, 1])
        XCTAssertEqual(ackRequests.count, 2)
        XCTAssertEqual(ackBody(0)["resultRevision"] as? Int, 0)
        XCTAssertEqual(ackBody(1)["resultRevision"] as? Int, 1)
        XCTAssertNotEqual(ackBody(0)["ackId"] as? String, ackBody(1)["ackId"] as? String)
    }

    func testARevisionWithTheSameWordsButDifferentFieldsIsStillANewRevision() async {
        // The summary can come out identical while the reported fields differ. The ack names a
        // revision, so revision 0's acknowledgement must not be allowed to cover revision 1.
        let rig = rig(ackingConfig(), outcomes: [.completed])
        var first = AgentRunResult()
        first.reported.insert(.filesCreated)
        var second = first
        second.reported.insert(.filesModified)

        rig.service.handle(.completed(first))
        await rig.service.awaitDelivery()
        rig.service.handle(.completed(second))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.deliveries.count, 2)
    }

    func testALocalCancellationIsADifferentResultFromARemoteOne() async {
        let rig = rig(ackingConfig(), outcomes: [.completed])
        rig.service.handle(.cancelled(AgentRunResult()))
        await rig.service.awaitDelivery()
        await rig.service.cancel()
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.deliveries.count, 2,
                       "\"the endpoint stopped it\" and \"you stopped it\" are different results")
    }

    func testTheOldRevisionIsNeverAckedAfterANewerOneArrives() async {
        var config = ackingConfig()
        config.ackURLTemplate = "https://agent.test/runs/{id}/ack"
        // Every ack attempt fails at the transport, so revision 0 is still retrying when
        // revision 1 lands.
        MockURLProtocol.script = [.networkFailure]

        let rig = rig(config, outcomes: [.completed])
        var revisionOneArrived = false
        rig.service.sleeper = { _ in
            guard !revisionOneArrived else { return }
            revisionOneArrived = true
            rig.service.handle(.completed(self.result("Revised.", files: ["a.swift"])))
        }
        rig.service.handle(.completed(result("First.")))
        await rig.service.awaitDelivery()

        let first = rig.service.deliveries.first { $0.resultRevision == 0 }
        XCTAssertEqual(first?.ackState, .unacknowledged(reason: .superseded),
                       "an ack naming revision 0 arriving after revision 1 was read out would "
                           + "tell the endpoint to suppress the wrong thing")
    }

    func testOnlyCompletedPlaybackProducesAnAcknowledgementAtAll() {
        for state in [AgentResultDelivery.State.pending, .playing, .interrupted, .suppressed, .failed] {
            let record = AgentResultDelivery(runID: "r", resultRevision: 0, state: state,
                                             ackState: .pending, at: fixedNow)
            XCTAssertNil(AgentDeliveryAck.for(record), "\(state) must not be acknowledgeable")
        }
        let completed = AgentResultDelivery(runID: "r", resultRevision: 0, state: .completed,
                                            ackState: .pending, at: fixedNow)
        XCTAssertEqual(AgentDeliveryAck.for(completed)?.deliveryState, .completed)
    }

    // MARK: - Ack failure

    func testAckTimeoutRetriesWithTheSameAckIdAndIsBounded() async {
        MockURLProtocol.script = [.timeout]
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(ackRequests.count, 3, "the first attempt plus the two the policy allows")
        let ids = Set((0..<ackRequests.count).compactMap { ackBody($0)["ackId"] as? String })
        XCTAssertEqual(ids.count, 1, "a retry is the same acknowledgement, not a second one")
    }

    func testAnAckFailureLeavesTheTaskCompleted() async {
        MockURLProtocol.script = [.networkFailure]
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.latestDelivery?.state, .completed,
                       "the wearer heard it; a POST that did not land does not un-hear it")
        XCTAssertEqual(rig.service.latestDelivery?.ackState, .unacknowledged(reason: .transport))
        XCTAssertEqual(rig.service.activeRun?.status, .completed)
        XCTAssertFalse(rig.spoken.value.contains { $0.lowercased().contains("acknowledge") },
                       "bookkeeping between two machines is not the wearer's problem")
    }

    func testAnEndpointRefusalIsNotRetried() async {
        MockURLProtocol.script = [.http(400)]
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(ackRequests.count, 1, "a 400 says this request will never work")
        XCTAssertEqual(rig.service.latestDelivery?.ackState,
                       .unacknowledged(reason: .endpointRefused))
    }

    func testAServerErrorIsRetriedWithinTheBound() async {
        MockURLProtocol.script = [.http(503)]
        let rig = rig(ackingConfig())
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()
        XCTAssertEqual(ackRequests.count, 3)
    }

    func testNoAckEndpointSendsNothingAndTheDeliveryStaysCompleted() async {
        var config = ackingConfig()
        config.ackURLTemplate = ""
        let rig = rig(config)
        rig.service.handle(.completed(result("Added the toggle.")))
        await rig.service.awaitDelivery()

        XCTAssertEqual(MockURLProtocol.requestCount, 0,
                       "an endpoint that never asked to be told is not told")
        XCTAssertEqual(rig.service.latestDelivery?.state, .completed)
        XCTAssertEqual(rig.service.latestDelivery?.ackState, .unacknowledged(reason: .unsupported))
        XCTAssertFalse(rig.service.latestDelivery?.ackIsUnresolved ?? true,
                       "nothing was owed, so nothing is outstanding")
    }

    // MARK: - Reconnect

    func testReconnectAfterLostContactDeliversOnce() async {
        MockURLProtocol.reset()
        MockURLProtocol.script = [
            .networkFailure,
            .json(#"{"status":"running"}"#),
            .json(#"{"status":"completed","result":{"summary":"Added the toggle."}}"#),
        ]
        let config = ackingConfig()
        let adapter = harness(config)
        let rig = rig(config)
        rig.service.setHarness(adapter)

        let run = AgentRun(id: "r1", harness: .custom, prompt: "p", project: "my-app",
                           status: .running, startedAt: fixedNow)
        for await event in adapter.events(for: run) { rig.service.handle(event) }
        await rig.service.awaitDelivery()

        XCTAssertEqual(rig.service.deliveries.count, 1,
                       "losing and regaining contact is not a second result")
        XCTAssertEqual(rig.service.deliveries.first?.state, .completed)
        XCTAssertEqual(ackRequests.count, 1)
    }

    // MARK: - The crash window

    func testAPendingRecordReloadsAsAmbiguous() {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 0, state: .playing,
                                       ackState: .pending, at: fixedNow))

        // A new process reads the same store.
        let reloaded = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        let record = reloaded.latest(forRun: "r1")
        XCTAssertEqual(record?.state, .playing)
        XCTAssertTrue(record?.reloaded ?? false)
        XCTAssertTrue(record?.deliveryIsAmbiguous ?? false)
    }

    func testACompletedRecordReloadsWithoutAmbiguityAboutTheWearer() {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 0, state: .completed,
                                       ackState: .unacknowledged(reason: .transport), at: fixedNow))
        let record = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite).latest(forRun: "r1")

        XCTAssertFalse(record?.deliveryIsAmbiguous ?? true,
                       "a failed POST is not a reason to doubt what the wearer heard")
        XCTAssertTrue(record?.ackIsUnresolved ?? false,
                      "but the endpoint's knowledge of it is genuinely unsettled")
    }

    func testAmbiguousReplayCopyClaimsNeitherWayAndDoesNotRereadTheResult() async {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 0, state: .playing,
                                       ackState: .pending, at: fixedNow))

        // A fresh session, as after a relaunch: the record survived, the words did not.
        let service = AgentSessionService()
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        service.speakResult = { line in spoken.append(line); return .completed }
        service.deliveryStore = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)

        let line = await service.replayLastResult()
        XCTAssertEqual(line, AgentDeliveryPhrasing.ambiguousWithoutWords)
        XCTAssertTrue(line.contains("may have"), "it hedges rather than picking a comfortable reading")
        XCTAssertFalse(line.contains("Done."), "the result itself was deliberately not persisted")
    }

    func testAmbiguousStatusLineSaysSoWithNoRunActive() {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 0, state: .pending,
                                       ackState: .pending, at: fixedNow))
        let service = AgentSessionService()
        service.deliveryStore = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)

        let line = service.currentStatusLine()
        XCTAssertTrue(line.contains("may have already read it"), "spoken: \(line)")
    }

    func testTheDeliveryIsWrittenBeforePlaybackIsRequested() async {
        // The crash window only exists because the record precedes the utterance. If it did not,
        // a crash during playback would leave no trace at all, which reads as "never happened".
        var seenDuringPlayback: AgentResultDelivery?
        let service = AgentSessionService()
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        service.now = { self.fixedNow }
        service.deliveryStore = store
        service.speak = { _ in }
        service.setHarness(harness(ackingConfig()))
        service.speakResult = { _ in
            seenDuringPlayback = store.latest(forRun: "r1")
            return .completed
        }
        service.handle(.started(AgentRun(id: "r1", harness: .custom, prompt: "p", project: nil,
                                         status: .running, startedAt: fixedNow)))
        service.handle(.completed(result("Added the toggle.")))
        await service.awaitDelivery()

        XCTAssertEqual(seenDuringPlayback?.state, .playing,
                       "a crash mid-playback must leave a record saying exactly that")
    }

    func testTheStoreKeepsOnlyTheNewestRuns() {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        for index in 0..<(AgentDeliveryRecordStore.limit + 3) {
            store.save(AgentResultDelivery(runID: "run\(index)", resultRevision: 0, state: .completed,
                                           ackState: .acknowledged,
                                           at: fixedNow.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(store.records.count, AgentDeliveryRecordStore.limit)
        XCTAssertNil(store.latest(forRun: "run0"))
        XCTAssertNotNil(store.latest(forRun: "run\(AgentDeliveryRecordStore.limit + 2)"))
    }

    func testBothRevisionsOfARunSurviveTogether() {
        let store = AgentDeliveryRecordStore(key: "deliveries", store: defaultsSuite)
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 0, state: .completed,
                                       ackState: .acknowledged, at: fixedNow))
        store.save(AgentResultDelivery(runID: "r1", resultRevision: 1, state: .completed,
                                       ackState: .pending, at: fixedNow.addingTimeInterval(1)))
        XCTAssertEqual(store.records(forRun: "r1").map(\.resultRevision), [0, 1])
        XCTAssertEqual(store.latest(forRun: "r1")?.resultRevision, 1)
    }

    // MARK: - Fingerprint

    func testFingerprintSeparatesReportedNothingFromReportedEmpty() {
        let silent = AgentRunResult()
        var reportedEmpty = AgentRunResult()
        reportedEmpty.reported.insert(.filesCreated)
        XCTAssertNotEqual(silent.deliveryFingerprint, reportedEmpty.deliveryFingerprint,
                          "\"it did not say\" and \"it said none\" are different reports (Plan FE P0)")
    }

    func testFingerprintIsStableForAnIdenticalReport() {
        let first = result("Added the toggle.", files: ["a.swift"])
        let second = result("Added the toggle.", files: ["a.swift"])
        XCTAssertEqual(first.deliveryFingerprint, second.deliveryFingerprint)
    }

    // MARK: - Config

    func testAckURLDecodesFromAConfigSavedBeforeItExisted() throws {
        let legacy = Data(#"{"name":"Mine","startURL":"https://agent.test/start","authValue":"tok"}"#.utf8)
        let config = try JSONDecoder().decode(CustomHarnessConfig.self, from: legacy)
        XCTAssertEqual(config.ackURLTemplate, "", "absent means never send, not a decode failure")
        XCTAssertEqual(config.authValue, "tok", "and the token survives")
        XCTAssertFalse(config.acceptsDeliveryAcks)
    }

    func testAckRequestIsNilWithoutATemplate() {
        var config = ackingConfig()
        config.ackURLTemplate = ""
        let ack = AgentDeliveryAck(runID: "r1", resultRevision: 0, deliveryState: .completed,
                                   ackID: "ack-x")
        XCTAssertNil(config.ackRequest(runID: "r1", ack: ack))
    }

    func testAckRunIdIsPercentEncodedIntoTheTemplate() {
        var config = ackingConfig()
        config.ackURLTemplate = "https://agent.test/runs/{id}/ack"
        let ack = AgentDeliveryAck(runID: "../evil", resultRevision: 0, deliveryState: .completed,
                                   ackID: "ack-x")
        let url = config.ackRequest(runID: "../evil", ack: ack)?.url?.absoluteString
        XCTAssertEqual(url, "https://agent.test/runs/..%2Fevil/ack",
                       "a run id the endpoint chose cannot rewrite the request path")
    }

    // MARK: - The tool surface

    func testTheReplayActionReachesTheSession() async throws {
        let shared = AgentSessionService.shared
        defer {
            shared.speakResult = nil
            shared.deliveryStore = nil
            shared.speak = { _ in }
        }
        shared.speak = { _ in }
        shared.speakResult = nil
        shared.deliveryStore = nil
        shared.handle(.completed(AgentRunResult()))

        let answer = try await AgentControlTool().execute(args: ["action": "replay"])
        XCTAssertTrue(answer.contains("Here it is again") || answer == AgentDeliveryPhrasing.nothingToReplay,
                      "answered: \(answer)")
    }

    func testAnUnknownActionNamesReplayAmongTheOptions() async throws {
        let answer = try await AgentControlTool().execute(args: ["action": "wobble"])
        XCTAssertTrue(answer.contains("replay"))
    }
}
