import XCTest
@testable import OpenGlasses

/// Plan KP P1b — whose the Display is (§8 rule 1), the busy hint's once-per-stretch rule (rule 5),
/// and the support report's record of each change. All pure.
///
/// Folded is not an input: the app does not read DAT's `hingeState`, so there is no folded signal
/// to combine. A folded pair reads as its link and worn state say.
final class DisplayAvailabilityTests: XCTestCase {

    private static let sessionStates: [DisplaySessionState?] = [nil] + DisplaySessionState.allCases
    private static let wornReadings: [Bool?] = [true, false, nil]

    /// Every combination of display, link, worn, session state and refused start, against the rule
    /// stated once more in plain terms.
    func testEveryCombination() {
        var checked = 0
        for hasDisplay in [true, false] {
            for connected in [true, false] {
                for worn in Self.wornReadings {
                    for state in Self.sessionStates {
                        for refused in [false, true] {
                            let reading = DisplaySessionReading(state: state, startRefused: refused)
                            let got = DisplayAvailability.read(hasDisplay: hasDisplay, connected: connected,
                                                               worn: worn, session: reading)
                            let expected: DisplayAvailability
                            if !hasDisplay || !connected || worn == false {
                                expected = .off
                            } else if state == .paused || refused {
                                expected = .inUse
                            } else {
                                expected = .ours
                            }
                            XCTAssertEqual(got, expected,
                                           "display \(hasDisplay) link \(connected) worn \(String(describing: worn)) "
                                           + "session \(reading.token)")
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 2 * 3 * 7 * 2)
    }

    func testAPausedSessionOnWornConnectedGlassesIsInUse() {
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: true,
                                                session: .init(state: .paused)), .inUse)
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: true,
                                                session: .init(state: nil, startRefused: true)), .inUse)
    }

    func testADisplayAsleepFromInactivityIsStillOurs() {
        // The session stays started while the lens sleeps; only `paused` or a refusal is in use.
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: true,
                                                session: .init(state: .started)), .ours)
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: true,
                                                session: .init()), .ours, "no session yet")
    }

    func testAnUnknownWornReadingIsNotTakenOff() {
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: nil,
                                                session: .init(state: .paused)), .inUse)
        XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: true, worn: false,
                                                session: .init(state: .paused)), .off)
    }

    func testDisconnectedOrNoDisplayIsOffWhateverTheSessionSays() {
        for state in Self.sessionStates {
            XCTAssertEqual(DisplayAvailability.read(hasDisplay: true, connected: false, worn: true,
                                                    session: .init(state: state, startRefused: true)), .off)
            XCTAssertEqual(DisplayAvailability.read(hasDisplay: false, connected: true, worn: true,
                                                    session: .init(state: state, startRefused: true)), .off)
        }
    }

    func testReadingTokensAreCaseNames() {
        XCTAssertEqual(DisplaySessionReading().token, "none")
        XCTAssertEqual(DisplaySessionReading(state: .paused).token, "paused")
        XCTAssertEqual(DisplaySessionReading(state: nil, startRefused: true).token, "none-refused")
        for state in DisplaySessionState.allCases {
            XCTAssertEqual(PrivacyToken(DisplaySessionReading(state: state, startRefused: true).token).description,
                           "\(state.rawValue)-refused", "a valid log token")
        }
        for availability in DisplayAvailability.allCases {
            XCTAssertEqual(PrivacyToken(availability.rawValue).description, availability.rawValue)
        }
    }

    // MARK: - The busy hint (rule 5)

    func testTheHintPlaysOncePerStretch() {
        var hint = DisplayBusyHint()
        hint.readingChanged(to: .inUse)
        XCTAssertTrue(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true))
        XCTAssertFalse(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true),
                       "once until the reading leaves in use")
        hint.readingChanged(to: .inUse)
        XCTAssertFalse(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true),
                       "the same reading again is the same stretch")

        hint.readingChanged(to: .ours)
        hint.readingChanged(to: .inUse)
        XCTAssertTrue(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true),
                      "a new stretch hints again")
    }

    func testLeavingThroughOffAlsoEndsTheStretch() {
        var hint = DisplayBusyHint()
        XCTAssertTrue(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true))
        hint.readingChanged(to: .off)
        hint.readingChanged(to: .inUse)
        XCTAssertTrue(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true))
    }

    func testTheHintNeverPlaysAfterAnythingButAnAnswer() {
        var hint = DisplayBusyHint()
        XCTAssertFalse(hint.claim(availability: .inUse, isAnswer: false, speechSuppressed: false, enabled: true))
        XCTAssertFalse(hint.givenThisStretch, "a refused claim does not use the stretch up")
        XCTAssertTrue(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: true))
    }

    func testTheHintNeverPlaysWhenOffOursSuppressedOrSwitchedOff() {
        var hint = DisplayBusyHint()
        XCTAssertFalse(hint.claim(availability: .off, isAnswer: true, speechSuppressed: false, enabled: true))
        XCTAssertFalse(hint.claim(availability: .ours, isAnswer: true, speechSuppressed: false, enabled: true))
        XCTAssertFalse(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: true, enabled: true))
        XCTAssertFalse(hint.claim(availability: .inUse, isAnswer: true, speechSuppressed: false, enabled: false))
        XCTAssertFalse(hint.givenThisStretch)
    }

    func testTheHintLineNamesWhatToSay() {
        let line = DisplayBusyHint.line
        XCTAssertTrue(line.contains("busy"))
        for words in ["repeat", "save that", "tell me more"] {
            XCTAssertTrue(line.contains(words), words)
        }
        XCTAssertFalse(line.contains("KP"), "no plan letters in what the wearer hears")
    }

    // MARK: - The support report's record

    func testTheLogKeepsTheNewestChangesWithTheirSessionState() {
        var log = DisplayAvailabilityLog(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(.ours, session: .init(state: .started), at: start)
        log.record(.inUse, session: .init(state: .paused), at: start.addingTimeInterval(5))
        log.record(.ours, session: .init(state: .started), at: start.addingTimeInterval(9))
        log.record(.off, session: .init(state: .stopped), at: start.addingTimeInterval(12))
        XCTAssertEqual(log.entries.count, 3, "bounded")
        XCTAssertEqual(log.entries.map(\.availability), [.inUse, .ours, .off])
        XCTAssertEqual(log.entries.first?.session.state, .paused)

        let lines = log.reportLines(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "Display readings (last 3, oldest first):")
        XCTAssertEqual(lines[1], "  2027-01-15 08:00:05: in use by another app (session paused)")
        XCTAssertEqual(lines[3], "  2027-01-15 08:00:12: off (session stopped)")
    }

    func testAnEmptyLogSaysSo() {
        XCTAssertEqual(DisplayAvailabilityLog().reportLines(), ["Display readings: none since launch"])
        XCTAssertEqual(DisplaySessionReading(state: nil, startRefused: true).reportName,
                       "no session, start refused")
    }
}
