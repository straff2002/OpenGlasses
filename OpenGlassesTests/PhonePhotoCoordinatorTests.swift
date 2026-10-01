import XCTest
@testable import OpenGlasses

/// Plan GV P1 — the request a camera tool waits on. Time is driven by hand: every sleep the
/// coordinator starts is parked until the test fires it, so nothing here depends on the clock.
@MainActor
final class PhonePhotoCoordinatorTests: XCTestCase {

    /// Parks each sleep until fired by its duration.
    @MainActor
    final class ManualSleeper {
        private var parked: [(seconds: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

        func sleep(_ seconds: TimeInterval) async {
            await withCheckedContinuation { parked.append((seconds, $0)) }
        }

        var parkedDurations: [TimeInterval] { parked.map(\.seconds) }

        func fireAll() {
            let due = parked
            parked = []
            due.forEach { $0.continuation.resume() }
        }

        func fire(_ seconds: TimeInterval) {
            let due = parked.filter { $0.seconds == seconds }
            parked.removeAll { $0.seconds == seconds }
            due.forEach { $0.continuation.resume() }
        }
    }

    private var sleeper: ManualSleeper!
    private var clock: Date!

    override func setUp() {
        super.setUp()
        sleeper = ManualSleeper()
        clock = Date(timeIntervalSince1970: 1_000)
    }

    override func tearDown() async throws {
        // Release every parked sleep so no continuation outlives its test; a timer whose request
        // already ended finds nothing to end.
        sleeper.fireAll()
        for _ in 0..<20 { await Task.yield() }
        try await super.tearDown()
    }

    private func makeCoordinator() -> PhonePhotoCoordinator {
        let sleeper = self.sleeper!
        return PhonePhotoCoordinator(timeout: 90, presentationGrace: 4, stagedLifetime: 120,
                                     sleep: { await sleeper.sleep($0) },
                                     now: { [unowned self] in self.clock })
    }

    /// Starts a request and waits until it is pending (or has already ended).
    private func start(_ coordinator: PhonePhotoCoordinator,
                       tool: String? = "capture_photo") async -> Task<PhonePhotoOutcome, Never> {
        let task = Task { await coordinator.requestPhoto(PhonePhotoRequest(toolName: tool, hint: "Frame it")) }
        for _ in 0..<200 where coordinator.pending == nil {
            await Task.yield()
        }
        return task
    }

    // MARK: - Endings

    func testThePhotoTheUserTakesIsReturned() async {
        let coordinator = makeCoordinator()
        let task = await start(coordinator)
        let request = try! XCTUnwrap(coordinator.pending)
        XCTAssertEqual(request.toolName, "capture_photo")
        coordinator.notePresented(request.id)
        coordinator.fulfil(request.id, data: Data([7]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .photo(Data([7])))
        XCTAssertNil(coordinator.pending, "the sheet closes")
    }

    func testCancellingTheCameraEndsTheWait() async {
        let coordinator = makeCoordinator()
        let task = await start(coordinator)
        coordinator.cancel(coordinator.pending!.id)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testNinetySecondsWithoutAPhotoTimesOut() async {
        let coordinator = makeCoordinator()
        let task = await start(coordinator)
        coordinator.notePresented(coordinator.pending!.id)
        sleeper.fire(4)   // the watchdog finds the camera on screen and stands down
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(coordinator.pending, "a presented camera is not ended by the watchdog")
        sleeper.fire(90)
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(coordinator.pending)
    }

    func testACameraThatNeverAppearsEndsAfterTheGrace() async {
        let coordinator = makeCoordinator()
        let task = await start(coordinator)
        sleeper.fire(4)
        let outcome = await task.value
        XCTAssertEqual(outcome, .couldNotPresent)
    }

    func testASecondRequestWhileOneIsOpenIsRejectedNotQueued() async {
        let coordinator = makeCoordinator()
        let first = await start(coordinator)
        let firstId = coordinator.pending!.id
        let second = await coordinator.requestPhoto(PhonePhotoRequest(toolName: "scan_code", hint: "x"))
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(coordinator.pending?.id, firstId, "the open request is untouched")
        coordinator.cancel(firstId)
        _ = await first.value
    }

    func testNoCameraIsShownWhenTheAppIsNotOnScreen() async {
        let coordinator = makeCoordinator()
        coordinator.isAppActive = { false }
        let outcome = await coordinator.requestPhoto(PhonePhotoRequest(toolName: "photo_log", hint: "x"))
        XCTAssertEqual(outcome, .appNotOnScreen)
        XCTAssertNil(coordinator.pending)
        XCTAssertTrue(sleeper.parkedDurations.isEmpty, "nothing was armed")
    }

    func testCancellingTheWaitingTaskClosesTheCamera() async {
        let coordinator = makeCoordinator()
        let task = await start(coordinator)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(coordinator.pending)
    }

    func testAStaleIdCannotEndANewerRequest() async {
        let coordinator = makeCoordinator()
        let first = await start(coordinator)
        let staleId = coordinator.pending!.id
        coordinator.cancel(staleId)
        _ = await first.value

        let second = await start(coordinator)
        coordinator.fulfil(staleId, data: Data([1]))
        coordinator.cancel(staleId)
        XCTAssertNotNil(coordinator.pending, "a late tap from the old sheet is ignored")
        coordinator.fulfil(coordinator.pending!.id, data: Data([2]))
        let outcome = await second.value
        XCTAssertEqual(outcome, .photo(Data([2])))
    }

    func testTheTurnsAudioStepsAsideWhileTheCameraIsOpen() async {
        let coordinator = makeCoordinator()
        var events: [String] = []
        coordinator.onWaitBegan = { events.append("began") }
        coordinator.onWaitEnded = { events.append("ended") }
        let task = await start(coordinator)
        XCTAssertEqual(events, ["began"])
        coordinator.cancel(coordinator.pending!.id)
        _ = await task.value
        XCTAssertEqual(events, ["began", "ended"])
    }

    // MARK: - Staged photo (tiles)

    func testATilesPhotoServesTheFirstToolRequestWithoutOpeningTheCamera() async {
        let coordinator = makeCoordinator()
        coordinator.stage(Data([5]))
        let first = await coordinator.requestPhoto(PhonePhotoRequest(toolName: "equipment_lookup", hint: "x"))
        XCTAssertEqual(first, .photo(Data([5])))
        XCTAssertTrue(sleeper.parkedDurations.isEmpty, "no camera was opened")
        XCTAssertFalse(coordinator.hasStagedPhoto, "the photo is used once")
    }

    func testAStagedPhotoExpires() async {
        let coordinator = makeCoordinator()
        coordinator.isAppActive = { false }   // so an expired photo ends at once rather than opening
        coordinator.stage(Data([5]))
        clock = clock.addingTimeInterval(121)
        let outcome = await coordinator.requestPhoto(PhonePhotoRequest(toolName: "photo_log", hint: "x"))
        XCTAssertEqual(outcome, .appNotOnScreen)
    }

    func testAClearedStagedPhotoIsGone() {
        let coordinator = makeCoordinator()
        coordinator.stage(Data([5]))
        XCTAssertTrue(coordinator.hasStagedPhoto)
        coordinator.clearStaged()
        XCTAssertFalse(coordinator.hasStagedPhoto)
    }

    func testATilesOwnPhotoNeverConsumesAStagedOne() async {
        let coordinator = makeCoordinator()
        coordinator.stage(Data([5]))
        let task = Task { await coordinator.preCapture(hint: "Frame it") }
        for _ in 0..<200 where coordinator.pending == nil { await Task.yield() }
        XCTAssertNil(coordinator.pending?.toolName)
        coordinator.fulfil(coordinator.pending!.id, data: Data([6]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .photo(Data([6])))
        XCTAssertTrue(coordinator.hasStagedPhoto)
    }
}
