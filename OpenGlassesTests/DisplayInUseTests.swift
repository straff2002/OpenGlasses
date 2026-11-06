#if !AVENKIN_PHONE_ONLY
import AVFoundation
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KP P1b — when another app has the Display (§8). Headless: the service and the card through
/// their test seams (the reading is driven with `applySessionReading`), the Meta backend through a
/// fake session (`testMakeSession`, never `Wearables.shared`), and the busy hint through the real
/// speech service over a recording synthesizer. No test waits on the clock: frames are awaited with
/// expectations, timers are captured and fired by hand, and the card's clock is a seam.
@MainActor
final class DisplayInUseTests: XCTestCase {

    // MARK: - Fixtures

    /// Records the frames the queue would send to the lens and fulfils waiters by count.
    @MainActor
    private final class FrameRecorder {
        private(set) var frames: [GlassesDisplayService.HUDFrame] = []
        private var waiters: [(count: Int, expectation: XCTestExpectation)] = []

        func record(_ frame: GlassesDisplayService.HUDFrame) {
            frames.append(frame)
            let ready = waiters.filter { frames.count >= $0.count }
            waiters.removeAll { frames.count >= $0.count }
            ready.forEach { $0.expectation.fulfill() }
        }

        /// An expectation fulfilled once `count` frames in all have been recorded.
        func expect(_ count: Int) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "\(count) frames")
            if frames.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
            return expectation
        }
    }

    private var savedDisplayEnabled = false
    private var savedBackend: String?
    private var savedHint = true
    private var savedTTSPreference: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        savedHint = Config.displayBusyHintEnabled
        savedTTSPreference = UserDefaults.standard.string(forKey: "ttsEnginePreference")
        Config.setGlassesDisplayEnabled(true)
        Config.displayBackend = .metaRayBan
        Config.setDisplayBusyHintEnabled(true)
    }

    override func tearDown() async throws {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        Config.setDisplayBusyHintEnabled(savedHint)
        UserDefaults.standard.set(savedTTSPreference, forKey: "ttsEnginePreference")
        try await super.tearDown()
    }

    private let longAnswer = """
        Turn the isolator off before you open the panel. Check the capacitor with a meter, because \
        it can hold a charge long after the power is off. If the reading is above five volts, \
        discharge it with a resistor rated for the job. Then swap the contactor, refit the cover, \
        restore the power and run the unit for ten minutes while you watch the pressures settle.
        """

    private func makeDisplay() -> (GlassesDisplayService, FrameRecorder) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        let recorder = FrameRecorder()
        display.testRenderSink = { recorder.record($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return (display, recorder)
    }

    private func makeCard(on display: GlassesDisplayService, clock: @escaping () -> Date) -> HUDAnswerCard {
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        card.now = clock
        card.scheduleIdleTimer = { _, _ in }      // lifetimes are judged by the clock here
        return card
    }

    /// Another app takes the Display: our session pauses.
    private func takeDisplay(_ display: GlassesDisplayService) {
        display.applySessionReading(.init(state: .paused))
        XCTAssertEqual(display.displayAvailability, .inUse)
    }

    /// The other app lets go: the session reports `started` again.
    private func giveDisplayBack(_ display: GlassesDisplayService) {
        display.applySessionReading(.init(state: .started))
        XCTAssertEqual(display.displayAvailability, .ours)
    }

    private func lastScreenKey(_ frames: [GlassesDisplayService.HUDFrame]) -> String? {
        for frame in frames.reversed() {
            if case .screen(let key) = frame { return key }
        }
        return nil
    }

    // MARK: - The reading on the service

    func testTheReadingFollowsSessionLinkAndWorn() {
        let (display, _) = makeDisplay()
        XCTAssertEqual(display.displayAvailability, .ours)
        takeDisplay(display)
        display.updateGlassesLink(connected: true, worn: false)
        XCTAssertEqual(display.displayAvailability, .off, "taken off")
        display.updateGlassesLink(connected: true, worn: true)
        XCTAssertEqual(display.displayAvailability, .inUse)
        display.updateGlassesLink(connected: false, worn: nil)
        XCTAssertEqual(display.displayAvailability, .off, "disconnected")
    }

    func testTheEvenBackendAlwaysReadsOurs() {
        Config.displayBackend = .evenG2
        let (display, _) = makeDisplay()
        display.applySessionReading(.init(state: .paused))
        XCTAssertEqual(display.displayAvailability, .ours, "only the Meta Display has a session to lose")
        let before = display.frameRevision
        display.showNotification(title: nil, body: "Battery low", duration: 5)
        XCTAssertEqual(display.frameRevision, before + 1, "nothing is held back")
    }

    // MARK: - No backlog (rule 3)

    func testNothingQueuesWhileInUse() async {
        let (display, recorder) = makeDisplay()
        display.showText("Caption before")
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        let mirrored = display.mirrorScreen?.renderKey

        takeDisplay(display)
        let revision = display.frameRevision
        display.showText("A caption")
        display.showText("An answer line", flashWhileInteractive: true)
        display.showNotification(title: "Calendar", body: "Meeting in five minutes")
        display.flash("Saved")
        display.clear()
        display.showNavigation("Turn left")

        XCTAssertEqual(display.frameRevision, revision, "nothing was handed to the queue")
        XCTAssertEqual(recorder.frames.count, 1, "nothing reached the lens")
        XCTAssertEqual(display.mirrorScreen?.renderKey, mirrored)
    }

    func testOnReturnTheLensGetsOneFrameNotTheBacklog() async {
        let (display, recorder) = makeDisplay()
        display.showText("Caption before")
        await fulfillment(of: [recorder.expect(1)], timeout: 5)

        takeDisplay(display)
        display.showNotification(title: nil, body: "One", duration: 5)
        display.showNotification(title: nil, body: "Two", duration: 5)
        display.showText("A caption")

        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(2)], timeout: 5)
        XCTAssertEqual(recorder.frames.count, 2)
        XCTAssertEqual(recorder.frames.last, .clear, "the stale caption is cleared; nothing dropped comes back")
    }

    func testATaskCardStartedWhileInUseIsDrawnOnReturn() async {
        let (display, recorder) = makeDisplay()
        takeDisplay(display)
        let screen = HUDScreen(title: "Step 1", items: [HUDItem(id: "done", label: "Done") {}])
        display.present(screen: screen) { _ in }
        XCTAssertTrue(display.isInteractive)
        XCTAssertTrue(recorder.frames.isEmpty)

        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        XCTAssertEqual(recorder.frames, [.screen(renderKey: screen.renderKey)])
    }

    // MARK: - The held card (rule 4)

    func testAnAnswerWhileInUseIsHeldAndShowsInsideItsLifetime() async {
        let (display, recorder) = makeDisplay()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(on: display) { now }

        takeDisplay(display)
        XCTAssertTrue(card.absorb(longAnswer, streamed: false), "the card holds the answer")
        XCTAssertTrue(display.showsAnswerCard)
        XCTAssertTrue(recorder.frames.isEmpty, "but nothing reaches the lens")

        now = now.addingTimeInterval(45)
        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        guard case .screen? = recorder.frames.last else { return XCTFail("the held card should show") }
        XCTAssertTrue(card.isShowing)
        XCTAssertEqual(display.mirrorScreen?.lines.last?.text, "1/\(card.pages.count)")
    }

    func testAHeldCardPastItsLifetimeIsDropped() async {
        let (display, recorder) = makeDisplay()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(on: display) { now }

        takeDisplay(display)
        card.absorb(longAnswer, streamed: false)

        now = now.addingTimeInterval(61)
        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        XCTAssertEqual(recorder.frames, [.clear])
        XCTAssertFalse(card.isShowing)
        XCTAssertFalse(display.isInteractive, "captions resume")
    }

    func testTheLifetimeCountsFromWhenTheAnswerWasMade() async {
        let (display, recorder) = makeDisplay()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(on: display) { now }

        card.absorb(longAnswer, streamed: false)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        card.press(.next)                   // a press is not a change to the answer
        await fulfillment(of: [recorder.expect(2)], timeout: 5)
        let page = lastScreenKey(recorder.frames)

        now = now.addingTimeInterval(30)
        takeDisplay(display)
        now = now.addingTimeInterval(29)    // 59 s after the answer was made
        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(3)], timeout: 5)
        XCTAssertEqual(lastScreenKey(recorder.frames), page, "back on the page the wearer left")
        XCTAssertEqual(card.pageIndex, 1)

        takeDisplay(display)
        now = now.addingTimeInterval(2)     // 61 s
        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(4)], timeout: 5)
        XCTAssertEqual(recorder.frames.last, .clear)
        XCTAssertFalse(card.isShowing)
    }

    func testANewerAnswerWhileInUseReplacesTheHeldOne() async {
        let (display, recorder) = makeDisplay()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(on: display) { now }

        takeDisplay(display)
        card.absorb(longAnswer, streamed: false)
        card.absorb("It takes about ten minutes.", streamed: false)
        XCTAssertEqual(card.answer, "It takes about ten minutes.", "only the latest card is kept")

        giveDisplayBack(display)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        XCTAssertEqual(recorder.frames.count, 1)
        XCTAssertEqual(display.mirrorScreen?.lines.map(\.text), ["It takes about ten minutes."])
    }

    func testPagingWordsGoToTheModelWhileInUse() async {
        let (display, recorder) = makeDisplay()
        let card = makeCard(on: display) { Date() }
        card.absorb(longAnswer, streamed: false)
        await fulfillment(of: [recorder.expect(1)], timeout: 5)
        XCTAssertTrue(card.canTurn(.next))

        takeDisplay(display)
        XCTAssertFalse(card.canTurn(.next), "the card can't be seen; \"next\" may mean the next track")
        XCTAssertFalse(card.canTurn(.close))

        giveDisplayBack(display)
        XCTAssertTrue(card.canTurn(.close))
    }

    // MARK: - The support report (P1b)

    func testEachChangeOfReadingIsRecordedWithItsSessionState() {
        let (display, _) = makeDisplay()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        display.now = { now }
        let before = display.availabilityLog.entries.count
        now = now.addingTimeInterval(10)
        takeDisplay(display)
        now = now.addingTimeInterval(10)
        giveDisplayBack(display)
        display.applySessionReading(.init(state: .started))    // no change: nothing recorded

        let entries = Array(display.availabilityLog.entries.dropFirst(before))
        XCTAssertEqual(entries.map(\.availability), [.inUse, .ours])
        XCTAssertEqual(entries.map(\.session.state), [.paused, .started])
        XCTAssertEqual(entries.first?.at, Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertTrue(display.availabilityReportLines.contains { $0.hasSuffix("in use by another app (session paused)") })
        XCTAssertEqual(display.availabilityReportLines.first, "Display reading now: ours (session started)")
    }

    // MARK: - The Meta backend never takes the Display back (rule 2)

    @MainActor
    private final class FakeDisplaySession: DisplaySessionControl {
        struct Refused: Error {}

        var sessionState: DisplaySessionState = .idle
        /// Where `start()` leaves the session.
        var stateOnStart: DisplaySessionState = .started
        var startError: Error?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private let stream: AsyncStream<DisplaySessionState>
        private let continuation: AsyncStream<DisplaySessionState>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: DisplaySessionState.self)
        }

        func start() throws {
            startCount += 1
            if let startError { throw startError }
            sessionState = stateOnStart
        }

        func stop() { stopCount += 1 }
        func stateUpdates() -> AsyncStream<DisplaySessionState> { stream }
        func addDisplay() throws -> Display { throw Refused() }

        /// The SDK reports a new state.
        func emit(_ state: DisplaySessionState) {
            sessionState = state
            continuation.yield(state)
        }
    }

    private func makeBackend(_ sessions: [FakeDisplaySession]) -> (MetaDisplayBackend, () -> Int) {
        let backend = MetaDisplayBackend()
        backend.testIsAvailable = true
        var made = 0
        backend.testMakeSession = {
            defer { made += 1 }
            return sessions[min(made, sessions.count - 1)]
        }
        return (backend, { made })
    }

    /// Wait until the backend reports a reading that satisfies `condition`.
    private func reading(of backend: MetaDisplayBackend,
                         _ condition: @escaping (DisplaySessionReading) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "session reading")
        if condition(backend.sessionReading) {
            expectation.fulfill()
        } else {
            backend.onSessionReading = { reading in
                if condition(reading) { expectation.fulfill() }
            }
        }
        return expectation
    }

    private func assertInUse(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected displayInUse", file: file, line: line)
        } catch GlassesDisplayError.displayInUse {
        } catch {
            XCTFail("expected displayInUse, got \(error)", file: file, line: line)
        }
    }

    func testAPausedSessionIsNeverStartedNorTornDown() async throws {
        let fake = FakeDisplaySession()
        let (backend, _) = makeBackend([fake])
        try await backend.prepareSession()
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(backend.sessionReading.state, .started)

        // Another app takes the Display.
        let paused = reading(of: backend) { $0.state == .paused }
        fake.emit(.paused)
        await fulfillment(of: [paused], timeout: 5)

        await assertInUse { try await backend.prepareSession() }
        await assertInUse { try await backend.send(screen: HUDScreen(title: "Answer")) }
        await assertInUse { try await backend.showContent(title: nil, body: "Caption", icon: .none) }
        backend.resetAfterError()            // what a render error would do
        XCTAssertEqual(fake.startCount, 1, "never started again")
        XCTAssertEqual(fake.stopCount, 0, "never torn down")

        // The other app lets go: the session comes back by itself, and is ours again.
        let started = reading(of: backend) { $0.state == .started }
        fake.emit(.started)
        await fulfillment(of: [started], timeout: 5)
        try await backend.prepareSession()
        XCTAssertEqual(fake.startCount, 1, "followed back, not restarted")
    }

    func testAStartThatLandsPausedIsFollowedNotRefused() async {
        let fake = FakeDisplaySession()
        fake.stateOnStart = .paused
        let (backend, _) = makeBackend([fake])
        await assertInUse { try await backend.prepareSession() }
        XCTAssertEqual(backend.sessionReading, DisplaySessionReading(state: .paused))
        XCTAssertEqual(fake.stopCount, 0)
        await assertInUse { try await backend.prepareSession() }
        XCTAssertEqual(fake.startCount, 1)
    }

    func testARefusedStartReadsInUseUntilItExpires() async throws {
        let refused = FakeDisplaySession()
        refused.startError = FakeDisplaySession.Refused()
        let later = FakeDisplaySession()
        let (backend, made) = makeBackend([refused, later])
        var expiries: [@MainActor () -> Void] = []
        backend.scheduleRefusalExpiry = { delay, fire in
            XCTAssertEqual(delay, MetaDisplayBackend.startRefusalExpiry)
            expiries.append(fire)
        }

        await assertInUse { try await backend.prepareSession() }
        XCTAssertTrue(backend.sessionReading.startRefused)
        XCTAssertEqual(refused.stopCount, 1, "a refused session is ours to drop")
        await assertInUse { try await backend.prepareSession() }
        XCTAssertEqual(made(), 1, "no second attempt while the refusal stands")
        XCTAssertEqual(refused.startCount, 1)

        XCTAssertEqual(expiries.count, 1)
        expiries[0]()
        XCTAssertFalse(backend.sessionReading.startRefused)
        try await backend.prepareSession()
        XCTAssertEqual(later.startCount, 1, "after the expiry the next frame tries once more")
    }

    func testAStartThatEndsStoppedIsARefusal() async {
        let fake = FakeDisplaySession()
        fake.stateOnStart = .stopped
        let (backend, _) = makeBackend([fake])
        backend.scheduleRefusalExpiry = { _, _ in }
        await assertInUse { try await backend.prepareSession() }
        XCTAssertTrue(backend.sessionReading.startRefused)
    }

    func testTurningTheHUDOffTearsDownEvenAPausedSession() async throws {
        let fake = FakeDisplaySession()
        let (backend, _) = makeBackend([fake])
        try await backend.prepareSession()
        let paused = reading(of: backend) { $0.state == .paused }
        fake.emit(.paused)
        await fulfillment(of: [paused], timeout: 5)

        await backend.shutdown()             // the wearer's own switch
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(backend.sessionReading, DisplaySessionReading())
    }

    // MARK: - The busy hint (rule 5), through the speech service

    /// Reports start and finish on the next main-queue turn; records what it was asked to say.
    private final class RecordingSynthesizer: SpeechSynthesizing {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        private let source = AVSpeechSynthesizer()
        var spoken: [String] = []

        func speak(_ utterance: AVSpeechUtterance) {
            spoken.append(utterance.speechString)
            let source = self.source
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.speechSynthesizer?(source, didStart: utterance)
                self?.delegate?.speechSynthesizer?(source, didFinish: utterance)
            }
        }

        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    }

    private func makeSpeech(display: GlassesDisplayService) -> (TextToSpeechService, RecordingSynthesizer) {
        Config.setTTSEnginePreference(.system)
        let synth = RecordingSynthesizer()
        let speech = TextToSpeechService(synthesizerFactory: { synth })
        speech.suppressionCheck = { nil }
        speech.glassesDisplay = display
        return (speech, synth)
    }

    private func hints(in spoken: [String]) -> Int {
        spoken.filter { $0.contains("busy") }.count
    }

    func testTheHintFollowsTheFirstAnswerOncePerStretch() async {
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)

        await speech.speak("The filter is behind the front grille.", source: .reply)
        XCTAssertEqual(synth.spoken.count, 2)
        XCTAssertEqual(hints(in: synth.spoken), 1, "the answer, then the hint")
        XCTAssertTrue(synth.spoken[0].contains("filter"))

        await speech.speak("It takes about ten minutes.", source: .phoneAnswer)
        XCTAssertEqual(synth.spoken.count, 3)
        XCTAssertEqual(hints(in: synth.spoken), 1, "once per stretch")

        giveDisplayBack(display)
        await speech.speak("Back on the lens.", source: .reply)
        XCTAssertEqual(hints(in: synth.spoken), 1, "never while the display is ours")

        takeDisplay(display)
        await speech.speak("A new stretch.", source: .reply)
        XCTAssertEqual(hints(in: synth.spoken), 2, "a new stretch hints again")
    }

    func testTheHintNeverFollowsAnAlert() async {
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)
        await speech.speak("Reminder: call the office.", source: .alert)
        await speech.speak("Saved.", source: .confirmation)
        XCTAssertEqual(synth.spoken.count, 2)
        XCTAssertEqual(hints(in: synth.spoken), 0)

        await speech.speak("The breaker is on the left.", source: .reply)
        XCTAssertEqual(hints(in: synth.spoken), 1, "the stretch was not used up by the alert")
    }

    func testTheHintNeverPlaysWhenTheDisplayIsOff() async {
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)
        display.updateGlassesLink(connected: true, worn: false)
        XCTAssertEqual(display.displayAvailability, .off)
        await speech.speak("The filter is behind the front grille.", source: .reply)
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(hints(in: synth.spoken), 0)
    }

    func testTheHintNeverPlaysWhileSpeechIsSuppressed() async {
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)
        speech.suppressionCheck = { .silentMode }
        await speech.speak("The filter is behind the front grille.", source: .reply)
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertFalse(speech.takeDisplayBusyHint(afterLineFrom: .reply))

        speech.suppressionCheck = { nil }
        await speech.speak("The filter is behind the front grille.", source: .reply)
        XCTAssertEqual(hints(in: synth.spoken), 1, "a suppressed answer did not use the stretch up")
    }

    func testTheHintIsOffWithTheSetting() async {
        Config.setDisplayBusyHintEnabled(false)
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)
        await speech.speak("The filter is behind the front grille.", source: .reply)
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(hints(in: synth.spoken), 0)
    }

    func testAStreamedAnswerIsFollowedByTheHint() async {
        let (display, _) = makeDisplay()
        let (speech, synth) = makeSpeech(display: display)
        takeDisplay(display)
        let reply = speech.beginStreamedReply(source: .reply)
        reply.enqueue("Turn the isolator off before you open the panel.")
        reply.enqueue("Then check the capacitor.")
        _ = await reply.finish()
        XCTAssertEqual(synth.spoken.count, 3)
        XCTAssertEqual(hints(in: synth.spoken), 1)
        XCTAssertTrue(synth.spoken[2].contains("busy"), "after the answer, not inside it")
    }
}
#endif
