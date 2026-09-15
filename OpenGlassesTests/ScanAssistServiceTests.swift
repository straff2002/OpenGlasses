import XCTest
@testable import OpenGlasses

/// Records what Scan Assist actually asked the speech service to do.
///
/// The assertions that matter in this file are about *absence* — a cue that was never spoken after
/// a stop, a side change or a pause — so the recorder has to be the same object for the whole
/// session rather than a snapshot taken at the end.
@MainActor
final class FakeScanAssistSpeech: ScanAssistSpeaking {
    private(set) var spoken: [String] = []
    private(set) var tones: [(frequency: Double, duration: Double)] = []
    private(set) var stopSpeakingCount = 0

    func speakCue(_ text: String) async { spoken.append(text) }
    func playTone(frequency: Double, duration: Double) { tones.append((frequency, duration)) }
    func stopSpeaking() { stopSpeakingCount += 1 }
}

/// A sleeper the test releases by hand, standing in for the real `Task.sleep`.
///
/// It sleeps for real, in very short slices, for one reason: `Task.sleep` throws the moment its
/// task is cancelled, so a cue task the service cancels unwinds here exactly as it would in the
/// app. A fake that returned immediately, or one parked on a continuation, would make the
/// cancellation path the one path these tests never exercise.
@MainActor
final class ReleasableSleeper {
    private(set) var requested: [TimeInterval] = []
    private var issued = 0
    /// A level, not a count: releasing is idempotent, so a cancelled sleep that is still unwinding
    /// can't swallow the release meant for the one that replaced it.
    private var releasedThrough = -1

    func sleep(_ seconds: TimeInterval) async {
        let ticket = issued
        issued += 1
        requested.append(seconds)
        while releasedThrough < ticket {
            do {
                try await Task.sleep(nanoseconds: 200_000)
            } catch {
                return   // cancelled — the wearer stopped, paused, or changed something
            }
        }
    }

    /// Let every sleep issued so far finish, as if its deadline had arrived. In practice there is
    /// exactly one outstanding: the service never arms two wake-ups.
    func fire() { releasedThrough = issued - 1 }
}

@MainActor
final class ScanAssistServiceTests: XCTestCase {

    final class FakeClock {
        var now: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ScanAssistSettingsStore!
    private var speech: FakeScanAssistSpeech!
    private var sleeper: ReleasableSleeper!
    private var clock: FakeClock!
    private var service: ScanAssistService!

    override func setUp() {
        super.setUp()
        suiteName = "ScanAssistServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ScanAssistSettingsStore(defaults: defaults)
        speech = FakeScanAssistSpeech()
        sleeper = ReleasableSleeper()
        clock = FakeClock()
        service = makeService()
    }

    override func tearDown() {
        service?.stop()
        service = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeService() -> ScanAssistService {
        let service = ScanAssistService(store: store, clock: { [clock] in clock!.now })
        service.sleeper = { [sleeper] seconds in await sleeper!.sleep(seconds) }
        service.configure(speech: speech)
        return service
    }

    // MARK: - Waiting helpers

    /// Deadline poll, not a fixed sleep: the assertion decides when to stop waiting, so a loaded
    /// machine makes the test slower rather than flaky.
    @discardableResult
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000)
        }
        let met = condition()
        if !met { XCTFail("timed out waiting for \(description)", file: file, line: line) }
        return met
    }

    /// Wait for the service to arm its next wake-up.
    private func waitForSchedule(count: Int,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        await waitUntil("\(count) scheduled sleep(s)", file: file, line: line) {
            self.sleeper.requested.count >= count
        }
    }

    /// Advance the clock and let the outstanding wake-up through.
    private func advanceAndFire(_ seconds: TimeInterval) {
        clock.advance(seconds)
        sleeper.fire()
    }

    /// Give the main actor a handful of turns so anything already queued can run. Used only to
    /// prove that nothing happens — an absence needs the opportunity to be violated.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Refusing without a side

    func testStartWithoutASideIsRefusedAndSaysNothing() async {
        XCTAssertFalse(service.start())
        await settle()

        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(speech.spoken.isEmpty, "a refusal is shown, never spoken over the wearer")
        XCTAssertTrue(speech.tones.isEmpty)
        XCTAssertTrue(sleeper.requested.isEmpty, "nothing may be scheduled without a chosen side")
        XCTAssertEqual(service.statusMessage, ScanAssistCopy.needsSideChoice)
    }

    func testPreviewWithoutASideIsRefusedAndSaysNothing() async {
        XCTAssertFalse(service.preview())
        await settle()
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertTrue(speech.tones.isEmpty)
        XCTAssertEqual(service.statusMessage, ScanAssistCopy.needsSideChoice)
    }

    // MARK: - Cue copy

    func testLeftSessionSpeaksTheLeftCue() async {
        service.chooseSide(.left)
        XCTAssertTrue(service.start())
        await waitForSchedule(count: 1)

        advanceAndFire(30)
        await waitUntil("the left cue") { self.speech.spoken.count == 1 }
        XCTAssertEqual(speech.spoken, ["Check to your left when you're ready."])
    }

    func testRightSessionSpeaksTheRightCue() async {
        service.chooseSide(.right)
        service.start()
        await waitForSchedule(count: 1)

        advanceAndFire(30)
        await waitUntil("the right cue") { self.speech.spoken.count == 1 }
        XCTAssertEqual(speech.spoken, ["Check to your right when you're ready."])
    }

    func testSoundStyleTonesInsteadOfSpeaking() async {
        service.chooseSide(.left)
        service.setCueStyle(.sound)
        service.start()
        await waitForSchedule(count: 1)

        advanceAndFire(30)
        await waitUntil("the tone") { self.speech.tones.count == 1 }
        XCTAssertTrue(speech.spoken.isEmpty, "a sound cue must not also say the side")
        XCTAssertEqual(speech.tones.first?.frequency, ScanAssistService.toneFrequency)
    }

    func testCuesKeepComingOnTheChosenInterval() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        advanceAndFire(30)
        await waitUntil("the first cue") { self.speech.spoken.count == 1 }
        await waitForSchedule(count: 2)

        advanceAndFire(30)
        await waitUntil("the second cue") { self.speech.spoken.count == 2 }
        XCTAssertEqual(speech.spoken.count, 2)
    }

    // MARK: - Repeated start

    func testASecondStartDoesNotCreateASecondSession() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)
        clock.advance(10)

        service.start()
        await settle()

        XCTAssertEqual(sleeper.requested.count, 1, "a second Start must not arm a second wake-up")
        XCTAssertEqual(service.remainingSeconds ?? 0, 290, accuracy: 0.001,
                       "and must not hand back a fresh session length")
    }

    // MARK: - Side change

    func testChangingSideNeverLetsTheOldSideCueThrough() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        clock.advance(10)
        service.chooseSide(.right)
        await waitForSchedule(count: 2)

        // Release the *old* sleep too, in case it is still unwinding: the guarantee is that it
        // cannot speak, not that it cannot exist.
        advanceAndFire(20)
        await waitUntil("the right cue") { self.speech.spoken.count == 1 }
        await settle()

        XCTAssertEqual(speech.spoken, ["Check to your right when you're ready."],
                       "the queued left cue must never reach the speaker")
    }

    // MARK: - Timing changes

    func testChangingTheIntervalReschedulesFromTheChange() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)
        XCTAssertEqual(sleeper.requested.first ?? 0, 30, accuracy: 0.001)

        clock.advance(20)
        service.setTiming(interval: .oneMinute, sessionDuration: .fiveMinutes)
        await waitForSchedule(count: 2)
        XCTAssertEqual(sleeper.requested.last ?? 0, 60, accuracy: 0.001,
                       "the new gap runs from the change, not from the old start")

        // The old 30-second deadline has now passed; nothing is owed for it.
        advanceAndFire(40)
        await settle()
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func testChangingTheSessionLengthMovesTheEnd() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        clock.advance(10)
        service.setTiming(interval: .thirtySeconds, sessionDuration: .twoMinutes)
        await waitForSchedule(count: 2)
        XCTAssertEqual(service.remainingSeconds ?? 0, 120, accuracy: 0.001)
    }

    // MARK: - Pause and resume

    func testPauseCancelsTheQueuedCueAndResumeStartsAFreshIntervalWithNoBacklog() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        clock.advance(25)
        service.pause()
        XCTAssertEqual(service.state, .paused)

        // Let a great deal of session time pass while paused, then release the cancelled sleep.
        advanceAndFire(600)
        await settle()
        XCTAssertTrue(speech.spoken.isEmpty, "a paused session speaks nothing")
        XCTAssertEqual(sleeper.requested.count, 1, "and arms nothing")

        service.resume()
        await waitForSchedule(count: 2)
        XCTAssertEqual(sleeper.requested.last ?? 0, 30, accuracy: 0.001,
                       "a whole interval from the resume")

        advanceAndFire(30)
        await waitUntil("one cue after resuming") { self.speech.spoken.count == 1 }
        await settle()
        XCTAssertEqual(speech.spoken.count, 1, "the twenty intervals that passed while paused are not owed")
    }

    // MARK: - Expiry

    func testTheSessionEndsItselfAndTakesItsPendingWorkWithIt() async {
        service.chooseSide(.left)
        // Interval and session length both two minutes: the session ends at the moment the first
        // reminder would have been due.
        service.setTiming(interval: .twoMinutes, sessionDuration: .twoMinutes)
        service.start()
        await waitForSchedule(count: 1)

        advanceAndFire(120)
        await waitUntil("the session to end") { self.service.state == .ended(.expired) }
        await settle()

        XCTAssertTrue(speech.spoken.isEmpty, "the session is over — the last reminder is not owed")
        XCTAssertEqual(speech.stopSpeakingCount, 1, "queued speech goes with the session")
        XCTAssertEqual(sleeper.requested.count, 1, "nothing is armed after the end")
        XCTAssertNil(service.remainingSeconds)
        XCTAssertEqual(service.statusMessage, ScanAssistCopy.sessionEnded(.expired))
    }

    // MARK: - Stopping

    func testStopCancelsThePendingCueAndTheQueuedSpeech() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        clock.advance(10)
        service.stop()
        XCTAssertEqual(service.state, .ended(.stopped))
        XCTAssertEqual(speech.stopSpeakingCount, 1)

        advanceAndFire(300)
        await settle()
        XCTAssertTrue(speech.spoken.isEmpty, "no cue may arrive after a stop")
        XCTAssertEqual(sleeper.requested.count, 1)
    }

    func testRepeatedStopIsHarmless() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        service.stop()
        service.stop()
        service.stop()
        await settle()

        XCTAssertEqual(speech.stopSpeakingCount, 1, "one ending, however many times Stop is pressed")
        XCTAssertEqual(service.state, .ended(.stopped))
    }

    func testStopBeforeAnySessionIsHarmless() async {
        service.stop()
        await settle()
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(speech.stopSpeakingCount, 0)
    }

    func testTurningTheFeatureOffEndsARunningSession() async {
        service.chooseSide(.left)
        service.setEnabled(true)
        service.start()
        await waitForSchedule(count: 1)

        service.setEnabled(false)
        advanceAndFire(300)
        await settle()

        XCTAssertEqual(service.state, .ended(.stopped))
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    /// The race the generation counter exists for: a wake-up that had already left its sleep when
    /// the wearer pressed Stop, arriving a moment later with a session id that no longer means
    /// anything.
    func testALateWakeUpAfterStopSaysNothing() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)
        let generationDuringSession = 1

        clock.advance(30)
        service.stop()

        service.wake(generation: generationDuringSession)
        await settle()

        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(service.state, .ended(.stopped), "a stale callback cannot revive a session")
    }

    func testALateWakeUpAfterASideChangeSaysNothing() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)

        clock.advance(30)
        service.chooseSide(.right)
        service.wake(generation: 1)   // the generation the left-side cue was scheduled under
        await settle()

        XCTAssertTrue(speech.spoken.isEmpty, "the cue belonged to a side the wearer has left behind")
    }

    // MARK: - Preview

    func testPreviewSpeaksOnceAndNamesTheSide() async {
        service.chooseSide(.left)
        XCTAssertTrue(service.preview())
        await waitUntil("the preview line") { self.speech.spoken.count == 1 }
        await settle()

        XCTAssertEqual(speech.spoken, ["Preview: check to your left when you're ready."])
        XCTAssertEqual(service.state, .idle, "a preview is not a session")
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    func testPreviewOfASoundCuePlaysTheSound() async {
        service.chooseSide(.right)
        service.setCueStyle(.sound)
        XCTAssertTrue(service.preview())
        await settle()

        XCTAssertEqual(speech.tones.count, 1)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    // MARK: - Nothing survives a relaunch

    func testAFreshServiceOverTheSameSettingsIsIdle() async {
        service.chooseSide(.left)
        service.start()
        await waitForSchedule(count: 1)
        XCTAssertEqual(service.state, .running)

        // Stand in for a relaunch: same persisted settings, brand-new service.
        let reopenedSleeper = ReleasableSleeper()
        let reopened = ScanAssistService(store: ScanAssistSettingsStore(defaults: defaults),
                                         clock: { [clock] in clock!.now })
        reopened.sleeper = { seconds in await reopenedSleeper.sleep(seconds) }
        reopened.configure(speech: speech)
        await settle()

        XCTAssertEqual(reopened.state, .idle, "reopening the app never resurrects a session")
        XCTAssertEqual(reopened.settings.side, .left, "the chosen side is remembered, though")
        XCTAssertTrue(reopenedSleeper.requested.isEmpty, "and nothing is armed on its own")

        service.stop()
    }
}

/// Persistence, in its own class so the defaults suite is built and torn down per test.
@MainActor
final class ScanAssistSettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ScanAssistSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreOffWithNoSideChosen() {
        let store = ScanAssistSettingsStore(defaults: defaults)
        XCTAssertFalse(store.settings.enabled)
        XCTAssertNil(store.settings.side, "a side is never assumed — it is answered")
        XCTAssertEqual(store.settings.cueStyle, .spoken)
        XCTAssertEqual(store.settings.interval, .thirtySeconds)
        XCTAssertEqual(store.settings.sessionDuration, .fiveMinutes)
    }

    func testEverySettingSurvivesAReload() {
        let store = ScanAssistSettingsStore(defaults: defaults)
        store.settings.enabled = true
        store.settings.side = .right
        store.settings.cueStyle = .sound
        store.settings.interval = .twoMinutes
        store.settings.sessionDuration = .tenMinutes

        let reopened = ScanAssistSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.settings, ScanAssistSettings(enabled: true,
                                                            side: .right,
                                                            cueStyle: .sound,
                                                            interval: .twoMinutes,
                                                            sessionDuration: .tenMinutes))
    }

    func testClearingTheSideIsPersistedAsNotChosen() {
        let store = ScanAssistSettingsStore(defaults: defaults)
        store.settings.side = .left
        store.settings.side = nil

        let reopened = ScanAssistSettingsStore(defaults: defaults)
        XCTAssertNil(reopened.settings.side)
    }

    /// An unrecognised stored value is "not chosen", not a guess. Anything else would mean a bad
    /// write, or a future migration, silently picking a side for someone.
    func testAnUnreadableStoredSideIsTreatedAsNotChosen() {
        defaults.set("sideways", forKey: ScanAssistSettingsStore.Key.side)
        let store = ScanAssistSettingsStore(defaults: defaults)
        XCTAssertNil(store.settings.side)
    }

    /// The accessibility screen reads this key with an `@AppStorage` literal, which no compiler
    /// check ties back to the store.
    func testTheEnabledKeyIsTheOneTheSettingsScreenReads() {
        XCTAssertEqual(ScanAssistSettingsStore.Key.enabled, "scanAssistEnabled")
    }

    func testNoRunningStateIsPersisted() {
        let store = ScanAssistSettingsStore(defaults: defaults)
        store.settings.enabled = true
        store.settings.side = .left

        let stored = Set(defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("scanAssist") })
        XCTAssertEqual(stored, Set(["scanAssistEnabled", "scanAssistSide",
                                    "scanAssistCueStyle", "scanAssistIntervalSeconds",
                                    "scanAssistSessionDurationSeconds"]),
                       "nothing about a live session may be written to disk")
    }
}

/// The wording the view and the speech service both read (docs/plans/FB-scan-assist.md: keep
/// efficacy language out of product copy, and keep left/right wearer-relative).
@MainActor
final class ScanAssistCopyTests: XCTestCase {

    func testCuesInviteRatherThanInstructAndNameTheSide() {
        XCTAssertEqual(ScanAssistCopy.cue(for: .left), "Check to your left when you're ready.")
        XCTAssertEqual(ScanAssistCopy.cue(for: .right), "Check to your right when you're ready.")
    }

    func testPreviewsAnnounceThemselvesAsPreviewsAndNameTheSide() {
        XCTAssertTrue(ScanAssistCopy.preview(for: .left).hasPrefix("Preview:"))
        XCTAssertTrue(ScanAssistCopy.preview(for: .left).contains("left"))
        XCTAssertTrue(ScanAssistCopy.preview(for: .right).contains("right"))
    }

    func testEverySideLabelSaysWhoseLeftItIs() {
        for side in ScanAssistSide.allCases {
            XCTAssertTrue(ScanAssistCopy.sideDescription(side).lowercased().contains("your own perspective"),
                          "\(side) must be described from the wearer's perspective")
        }
    }

    func testControlLabelsAreWordsNotGlyphs() {
        XCTAssertEqual(ScanAssistCopy.sideLabel(.left), "Left")
        XCTAssertEqual(ScanAssistCopy.sideLabel(.right), "Right")
        XCTAssertEqual(ScanAssistCopy.cueStyleLabel(.spoken), "Spoken direction")
        XCTAssertEqual(ScanAssistCopy.cueStyleLabel(.sound), "Gentle sound")
        XCTAssertEqual(ScanAssistCopy.intervalLabel(.oneMinute), "Every minute")
        XCTAssertEqual(ScanAssistCopy.sessionDurationLabel(.tenMinutes), "10 minutes")
    }

    func testTheCountdownIsSpokenAsWords() {
        XCTAssertEqual(ScanAssistCopy.remaining(seconds: 270), "4 min 30 sec left")
        XCTAssertEqual(ScanAssistCopy.remaining(seconds: 120), "2 min left")
        XCTAssertEqual(ScanAssistCopy.remaining(seconds: 9), "9 sec left")
        XCTAssertEqual(ScanAssistCopy.remaining(seconds: -5), "0 sec left")
    }

    /// The observation boundary, as a test. Scan Assist has no camera and no attention model, so
    /// no line of its copy may imply it knows what the wearer did.
    func testNoCopyClaimsToKnowWhatTheWearerLookedAt() {
        var lines = [ScanAssistCopy.needsSideChoice,
                     ScanAssistCopy.sessionRunning,
                     ScanAssistCopy.sessionPaused,
                     ScanAssistCopy.sessionEnded(.stopped),
                     ScanAssistCopy.sessionEnded(.expired),
                     ScanAssistCopy.sideNotChosen]
        for side in ScanAssistSide.allCases {
            lines.append(contentsOf: [ScanAssistCopy.cue(for: side),
                                      ScanAssistCopy.preview(for: side),
                                      ScanAssistCopy.sideLabel(side),
                                      ScanAssistCopy.sideDescription(side)])
        }
        let forbidden = ["you missed", "you checked", "safe to proceed", "well done",
                         "treat", "therapy", "improve", "recovered", "score"]
        for line in lines {
            let lowered = line.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(lowered.contains(phrase),
                               "\"\(line)\" claims something Scan Assist cannot know or do")
            }
        }
    }
}
