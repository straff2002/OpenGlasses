import XCTest
@testable import OpenGlasses

/// Plan FE P3 — the wearer's pause setting: what it defaults to, what it refuses to be, when a
/// change takes effect, and the two rules it must never break (the question window may only widen
/// it; the stuck-detector backstop must always outlast it).
final class SpeechPauseSettingsTests: XCTestCase {

    private let pauseKey = "speechPauseWindow"
    private let bargeInKey = "speechBargeInEnabled"
    private var savedPause: Any?
    private var savedBargeIn: Any?

    override func setUp() {
        super.setUp()
        savedPause = UserDefaults.standard.object(forKey: pauseKey)
        savedBargeIn = UserDefaults.standard.object(forKey: bargeInKey)
        UserDefaults.standard.removeObject(forKey: pauseKey)
        UserDefaults.standard.removeObject(forKey: bargeInKey)
    }

    override func tearDown() {
        if let savedPause { UserDefaults.standard.set(savedPause, forKey: pauseKey) }
        else { UserDefaults.standard.removeObject(forKey: pauseKey) }
        if let savedBargeIn { UserDefaults.standard.set(savedBargeIn, forKey: bargeInKey) }
        else { UserDefaults.standard.removeObject(forKey: bargeInKey) }
        super.tearDown()
    }

    // MARK: - Defaults and migration

    /// An install that predates the setting has no stored value at all. It must behave exactly as
    /// it did before — 2.0 s and barge-in on — rather than inheriting a bound or an empty value.
    func testAnInstallWithNoStoredValueKeepsTodaysBehaviour() {
        XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.baseWindow)
        XCTAssertTrue(Config.speechBargeInEnabled)
    }

    /// Every unusable stored value resolves to the default, not to the nearest bound: a 1-second
    /// window from a NaN would cut people off, a 10-second one would hang the mic, and neither is
    /// a better guess at what the wearer wanted than the value they would have had anyway.
    func testUnusableStoredValuesFallBackToTheDefaultNotToABound() {
        let unusable: [Double] = [.nan, .infinity, -.infinity, -3.0, 0.0]
        for value in unusable {
            UserDefaults.standard.set(value, forKey: pauseKey)
            XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.baseWindow,
                           "stored \(value) must resolve to the default")
        }
    }

    /// A value of the wrong type entirely — a hand-edited plist, a key collision, an older build
    /// that stored a string — must not crash and must not produce a zero window.
    func testAStoredValueOfTheWrongTypeResolvesToTheDefault() {
        UserDefaults.standard.set("dictation", forKey: pauseKey)
        XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.baseWindow)
    }

    /// Out-of-range but otherwise sane numbers are clamped rather than discarded: someone who
    /// stored 30 s wanted "as long as possible", and the ceiling is the honest answer.
    func testOutOfRangeValuesAreClampedToTheAllowedWindow() {
        UserDefaults.standard.set(900.0, forKey: pauseKey)
        XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.maximumWindow)

        UserDefaults.standard.set(0.25, forKey: pauseKey)
        XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.minimumWindow)
    }

    /// The setter clamps too, so a bad value can never reach the store in the first place.
    func testTheSetterClampsBeforeItPersists() {
        Config.setSpeechPauseWindow(.nan)
        XCTAssertEqual(Config.speechPauseWindow, SpeechContinuationPolicy.baseWindow)

        Config.setSpeechPauseWindow(60)
        XCTAssertEqual(UserDefaults.standard.double(forKey: pauseKey),
                       SpeechContinuationPolicy.maximumWindow)
    }

    /// Every preset offered in Settings must survive a round trip unchanged — a preset the clamp
    /// moves is a control that silently disagrees with its own label.
    func testEveryPresetRoundTripsExactly() {
        for preset in SpeechContinuationPolicy.presetWindows {
            Config.setSpeechPauseWindow(preset)
            XCTAssertEqual(Config.speechPauseWindow, preset, accuracy: 0.0001)
            XCTAssertEqual(SpeechContinuationPolicy.nearestPreset(to: preset), preset, accuracy: 0.0001)
        }
    }

    /// A stored window that is not one of the rungs still has to render as one.
    func testAnOffLadderValueStillSelectsAPreset() {
        XCTAssertEqual(SpeechContinuationPolicy.nearestPreset(to: 3.4), 3.0, accuracy: 0.0001)
        XCTAssertEqual(SpeechContinuationPolicy.nearestPreset(to: 9.5), 6.0, accuracy: 0.0001)
        XCTAssertEqual(SpeechContinuationPolicy.nearestPreset(to: .nan),
                       SpeechContinuationPolicy.baseWindow, accuracy: 0.0001)
    }

    func testTheBargeInSwitchPersistsBothWays() {
        Config.setSpeechBargeInEnabled(false)
        XCTAssertFalse(Config.speechBargeInEnabled)
        Config.setSpeechBargeInEnabled(true)
        XCTAssertTrue(Config.speechBargeInEnabled)
    }

    // MARK: - Adoption: a change applies from the next turn

    /// The promise the settings footer makes. A turn started under one window keeps it for its
    /// whole life; the change lands on the turn after.
    func testATurnKeepsTheWindowItStartedWith() {
        var ledger = SpeechTurnWindowLedger()

        XCTAssertEqual(ledger.beginTurn(userWindow: 1.5), 1.5, accuracy: 0.0001)
        XCTAssertEqual(ledger.currentWindow, 1.5, accuracy: 0.0001,
                       "the running turn must not adopt anything mid-utterance")

        // The wearer changes the setting while that turn is still in flight. Nothing re-arms.
        XCTAssertEqual(ledger.currentWindow, 1.5, accuracy: 0.0001)

        // Next turn picks it up.
        XCTAssertEqual(ledger.beginTurn(userWindow: 6.0), 6.0, accuracy: 0.0001)
        XCTAssertEqual(ledger.currentWindow, 6.0, accuracy: 0.0001)
    }

    /// The assistant speaking mid-turn must not re-arm the running window either — it only sets up
    /// what the *next* turn will use.
    func testNotingTheAssistantSpokeDoesNotMoveTheRunningWindow() {
        var ledger = SpeechTurnWindowLedger()
        ledger.beginTurn(userWindow: 2.0)
        ledger.noteAssistantSpoke("Which Sam do you mean?")
        XCTAssertEqual(ledger.currentWindow, 2.0, accuracy: 0.0001)

        XCTAssertEqual(ledger.beginTurn(userWindow: 2.0),
                       SpeechContinuationPolicy.questionWindow, accuracy: 0.0001)
        XCTAssertTrue(ledger.isQuestionWidened)
    }

    /// A ledger seeded from a nonsense window still starts somewhere usable.
    func testTheLedgerClampsItsSeedWindow() {
        XCTAssertEqual(SpeechTurnWindowLedger(currentWindow: .nan).currentWindow,
                       SpeechContinuationPolicy.baseWindow, accuracy: 0.0001)
    }

    // MARK: - Long dictation pause and short reply

    /// Six seconds means six seconds: a 2.5 s thinking pause mid-dictation must not commit.
    func testALongDictationWindowDoesNotCommitAtTheOldTwoSecondFloor() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = SpeechTurnWindowLedger()
        let window = ledger.beginTurn(userWindow: 6.0)
        XCTAssertEqual(window, 6.0, accuracy: 0.0001)

        func decision(at seconds: TimeInterval) -> EndOfTurnPolicy.Decision {
            EndOfTurnPolicy.decide(.init(now: epoch.addingTimeInterval(seconds),
                                         detectorAvailable: false,
                                         speechObserved: true,
                                         lastRecognizerActivityAt: epoch,
                                         acousticSpeechEndedAt: nil,
                                         timerWindow: window))
        }

        XCTAssertEqual(decision(at: 2.5), .wait(until: epoch.addingTimeInterval(6.0)),
                       "a pause between sentences is not the end of a dictated paragraph")
        XCTAssertEqual(decision(at: 6.0), .commit(.silenceTimer))
    }

    /// And the short end still feels short: 1.5 s commits at 1.5 s, not at the old 2.0 s.
    func testAShortWindowCommitsQuickly() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = SpeechTurnWindowLedger()
        let window = ledger.beginTurn(userWindow: 1.5)

        let waiting = EndOfTurnPolicy.decide(.init(now: epoch.addingTimeInterval(1.4),
                                                   detectorAvailable: false,
                                                   speechObserved: true,
                                                   lastRecognizerActivityAt: epoch,
                                                   acousticSpeechEndedAt: nil,
                                                   timerWindow: window))
        XCTAssertEqual(waiting, .wait(until: epoch.addingTimeInterval(1.5)))

        let committed = EndOfTurnPolicy.decide(.init(now: epoch.addingTimeInterval(1.5),
                                                     detectorAvailable: false,
                                                     speechObserved: true,
                                                     lastRecognizerActivityAt: epoch,
                                                     acousticSpeechEndedAt: nil,
                                                     timerWindow: window))
        XCTAssertEqual(committed, .commit(.silenceTimer))
    }

    // MARK: - The question rule may only widen

    /// The inverted-CO bug: a wearer who asked for a long pause must not have it cut to 6 s just
    /// because the assistant's reply ended in a question.
    func testAQuestionNeverShortensALongerChosenWindow() {
        for window in [7.0, 8.0, SpeechContinuationPolicy.maximumWindow] {
            let after = SpeechContinuationPolicy.silenceWindow(afterSpeaking: "Should I save that?",
                                                               userWindow: window)
            XCTAssertEqual(after, window, accuracy: 0.0001,
                           "the question rule widens; it must never shorten")
        }
    }

    /// And it still widens a short one — someone on 1.5 s still gets time to think about an answer.
    func testAQuestionStillWidensAShortChosenWindow() {
        let after = SpeechContinuationPolicy.silenceWindow(afterSpeaking: "Which one did you mean",
                                                           userWindow: 1.5)
        XCTAssertEqual(after, SpeechContinuationPolicy.questionWindow, accuracy: 0.0001)
    }

    /// A statement leaves the chosen window exactly alone in both directions.
    func testAStatementLeavesTheChosenWindowAlone() {
        for window in SpeechContinuationPolicy.presetWindows {
            XCTAssertEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: "It's 14 degrees.",
                                                                  userWindow: window),
                           window, accuracy: 0.0001)
        }
    }

    /// The single-argument form is what every pre-FE fixture calls; it must still mean "default".
    func testTheDefaultedOverloadIsUnchanged() {
        XCTAssertEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: nil),
                       SpeechContinuationPolicy.baseWindow, accuracy: 0.0001)
        XCTAssertEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: "Which one?"),
                       SpeechContinuationPolicy.questionWindow, accuracy: 0.0001)
    }

    // MARK: - The backstop must outlast every allowed window

    /// Rule 4 handing the decision back *before* rule 3's window expires would cut off exactly the
    /// wearers who asked for a long pause — and only them.
    func testTheBackstopCannotPreemptAnyAllowedWindow() {
        var windows = SpeechContinuationPolicy.presetWindows
        windows.append(contentsOf: [SpeechContinuationPolicy.minimumWindow,
                                    SpeechContinuationPolicy.maximumWindow,
                                    SpeechContinuationPolicy.questionWindow])
        for window in windows {
            XCTAssertGreaterThan(EndOfTurnPolicy.backstop(forWindow: window), window,
                                 "backstop must outlast a \(window)s window")
        }
        XCTAssertEqual(EndOfTurnPolicy.backstop(forWindow: SpeechContinuationPolicy.baseWindow),
                       EndOfTurnPolicy.stuckDetectorBackstop, accuracy: 0.0001,
                       "the historical floor is unchanged for the default window")
    }

    /// And the derived hold is what `decide` actually uses, not just a constant sitting nearby.
    func testDecideUsesTheDerivedHoldForTheLongestWindow() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let window = SpeechContinuationPolicy.maximumWindow
        let expected = EndOfTurnPolicy.backstop(forWindow: window)

        let holding = EndOfTurnPolicy.decide(.init(now: epoch.addingTimeInterval(window),
                                                    detectorAvailable: true,
                                                    speechObserved: true,
                                                    lastRecognizerActivityAt: epoch,
                                                    acousticSpeechEndedAt: nil,
                                                    timerWindow: window))
        XCTAssertEqual(holding, .wait(until: epoch.addingTimeInterval(expected)),
                       "a detector that still hears speech must outlast the wearer's own window")

        let handedBack = EndOfTurnPolicy.decide(.init(now: epoch.addingTimeInterval(expected),
                                                      detectorAvailable: true,
                                                      speechObserved: true,
                                                      lastRecognizerActivityAt: epoch,
                                                      acousticSpeechEndedAt: nil,
                                                      timerWindow: window))
        XCTAssertEqual(handedBack, .commit(.detectorBackstop))
    }

    /// An explicit backstop may lengthen the hold but can never pull it below the window.
    func testAnExplicitBackstopCannotUndercutTheWindow() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let window = SpeechContinuationPolicy.maximumWindow
        var input = EndOfTurnPolicy.Input(now: epoch.addingTimeInterval(window),
                                          detectorAvailable: true,
                                          speechObserved: true,
                                          lastRecognizerActivityAt: epoch,
                                          acousticSpeechEndedAt: nil,
                                          timerWindow: window)
        input.backstop = 1.0
        XCTAssertEqual(EndOfTurnPolicy.decide(input),
                       .wait(until: epoch.addingTimeInterval(EndOfTurnPolicy.backstop(forWindow: window))))
    }
}
