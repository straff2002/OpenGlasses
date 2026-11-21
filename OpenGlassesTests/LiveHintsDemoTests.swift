import XCTest
@testable import OpenGlasses

/// A clock that keeps every repeating tick it is given, so the session's tick and the demo's
/// conversation both run on one fake time.
@MainActor
final class MultiTickHintClock: HintClock {
    var now: Date
    private var ticks: [Int: @MainActor () -> Void] = [:]
    private var nextID = 0

    init(now: Date) { self.now = now }

    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        ticks[id] = tick
        return { [weak self] in self?.ticks[id] = nil }
    }

    var tickCount: Int { ticks.count }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for tick in ticks.values { tick() }
    }
}

/// Plan MO P2 (§11): the demo session — its script, its sample document, that it never opens the
/// microphone, and that its first hint arrives within about 10 s, through the real session code.
@MainActor
final class LiveHintsDemoTests: XCTestCase {

    private var clock: MultiTickHintClock!
    private var model: FakeHintModel!
    private var lens: FakeHintLens!
    private var ear: FakeHintEar!
    private var list: LiveHintsPhoneList!

    override func setUp() async throws {
        clock = MultiTickHintClock(now: Date(timeIntervalSinceReferenceDate: 900_000_000))
        model = FakeHintModel()
        model.isAvailable = false
        lens = FakeHintLens()
        ear = FakeHintEar()
        list = LiveHintsPhoneList()
    }

    private func makeDemo() -> (LiveHintsService, DemoHintCaptionSource) {
        let built = LiveHintsDemo.carriers(model: model, lens: lens, ear: ear, phoneList: list, clock: clock)
        let service = LiveHintsService(carriers: built.carriers)
        service.isEnabled = { true }
        service.firstRunAcknowledged = { true }
        service.setFirstRunAcknowledged = { _ in }
        service.captureNotice = LiveHintsCopy.demoNotice
        built.captions.onFinished = { [weak service] in service?.stop(reason: .demoEnded) }
        return (service, built.captions)
    }

    /// Run the fake clock in quarter seconds until `until` from the start, letting each answer land.
    private func run(_ service: LiveHintsService, until seconds: TimeInterval,
                     stopWhen done: () -> Bool = { false }) async -> TimeInterval {
        var elapsed: TimeInterval = 0
        while elapsed < seconds - 0.0001 {
            clock.advance(by: 0.25)
            elapsed += 0.25
            await service.waitUntilIdle()
            if done() { break }
        }
        return elapsed
    }

    // MARK: - The script

    func testTheFirstQuestionIsAskedWellInsideTenSeconds() {
        XCTAssertLessThan(LiveHintsDemo.firstQuestionAt, 6)
        XCTAssertGreaterThan(LiveHintsDemo.firstQuestionAt, 0)
    }

    func testTheConversationHasTwoVoicesInOrderAndEndsAfterItsLastLine() {
        let times = LiveHintsDemo.lines.map(\.at)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(LiveHintsDemo.lines.map(\.speaker)), [LiveHintsDemo.wearerSpeaker, LiveHintsDemo.visitorSpeaker])
        XCTAssertGreaterThan(LiveHintsDemo.endsAt, times.last ?? 0)
        XCTAssertFalse(LiveHintsDemo.lines.contains { $0.speaker == LiveHintsDemo.wearerSpeaker && $0.text.hasSuffix("?") },
                       "the wearer asks nothing, so marking their voice changes nothing in the demo")
    }

    func testTheSampleDocumentHoldsNoPrice() {
        let text = LiveHintsDemo.passages.joined(separator: " ")
        for mark in ["$", "£", "€", "¥", "price", "cost"] {
            XCTAssertFalse(text.lowercased().contains(mark), mark)
        }
    }

    // MARK: - It never touches the microphone

    func testTheDemosCarriersHearNothingAndChargeNothing() {
        let built = LiveHintsDemo.carriers(model: model, lens: lens, ear: ear, phoneList: list, clock: clock)
        XCTAssertTrue(built.carriers.voiceActivity is SilentHintVoiceActivity, "no mic level")
        XCTAssertTrue(built.carriers.captions is DemoHintCaptionSource, "no caption service")
        XCTAssertTrue(built.carriers.documents is DemoHintDocuments, "only the sample document")
        XCTAssertNil(built.carriers.allowance.remaining(), "the daily allowance is not drawn on")
    }

    // MARK: - Through the real session

    func testTheFirstHintArrivesWithinTenSeconds() async {
        let (service, _) = makeDemo()
        XCTAssertEqual(service.start(), .started)
        XCTAssertEqual(service.notice, LiveHintsCopy.demoNotice)
        let elapsed = await run(service, until: 10) { !list.hints.isEmpty }
        XCTAssertFalse(list.hints.isEmpty, "a hint by 10 s")
        XCTAssertLessThanOrEqual(elapsed, 10)
        XCTAssertEqual(list.hints.first?.passage?.documentId, LiveHintsDemo.documentId)
        XCTAssertTrue(list.hints.first?.line.contains("3 days") == true, list.hints.first?.line ?? "")
        XCTAssertEqual(lens.presented.count, 1, "on the lens, through the same delivery as a real hint")
        service.stop()
    }

    func testEveryQuestionIsHintedAndTheDemoStopsItself() async {
        let (service, captions) = makeDemo()
        service.start()
        _ = await run(service, until: LiveHintsDemo.endsAt + 1) { !service.isRunning }
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.lastStopReason, .demoEnded)
        XCTAssertFalse(captions.isActive, "its conversation stopped with it")
        XCTAssertEqual(clock.tickCount, 0, "nothing left ticking")
        XCTAssertGreaterThanOrEqual(service.hintsShown, 4)
    }

    func testEachQuestionFindsItsOwnPassage() {
        let documents = DemoHintDocuments()
        let questions = LiveHintsDemo.lines.filter { $0.text.hasSuffix("?") }.map(\.text)
        let picked = questions.map { PassageHint.pick(from: documents.passages(for: $0, limit: 4), for: $0)?.chunkIndex }
        XCTAssertEqual(picked, [1, 2, 3, 4])
        XCTAssertEqual(documents.documentTitles(), [LiveHintsDemo.documentName])
    }

    func testADemoHintOpensItsSamplePassage() {
        XCTAssertEqual(LiveHintsDemo.passageText(documentId: LiveHintsDemo.documentId, chunkIndex: 2),
                       LiveHintsDemo.passages[2])
        XCTAssertNil(LiveHintsDemo.passageText(documentId: "someone-elses", chunkIndex: 2))
        XCTAssertNil(LiveHintsDemo.passageText(documentId: LiveHintsDemo.documentId, chunkIndex: 99))
    }
}
