import XCTest
@testable import OpenGlasses

/// Plan LE P0 §4 and §10 — the check-in as a third `MyDayDeliveryPolicy` slot: its own switch,
/// time and day key; the same window, quiet hours and speech rules; one delivery with the evening
/// briefing inside 30 minutes; 17:00 with Field Assist on; and not spoken while driving.
final class MyDayCheckInDeliveryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 11, day: 14, hour: hour, minute: minute).date!
    }

    private let dayKey = "2026-11-14"

    private func settings(checkIn: Bool = true, at checkInMinutes: Int? = nil, evening: Bool = false,
                          eveningMinutes: Int = 19 * 60, fieldAssist: Bool = false,
                          quiet: Bool = false, speech: Bool = true) -> MyDayDeliverySettings {
        MyDayDeliverySettings(
            myDayEnabled: true, morningEnabled: false, morningMinutes: 8 * 60,
            eveningEnabled: evening, eveningMinutes: eveningMinutes,
            scheduledSpeechEnabled: speech, quietHoursEnabled: quiet,
            quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60,
            checkInEnabled: checkIn, checkInMinutes: checkInMinutes, fieldAssistOn: fieldAssist)
    }

    private func context(motion: MotionSample.Kind? = nil, presence: EngagementMode = .active) -> MyDayDeliveryContext {
        MyDayDeliveryContext(presence: presence, power: .normal, isOnline: true, isBusy: false,
                             sourceAccessReady: true, isProtectedDataAvailable: true, motion: motion)
    }

    private func decide(_ now: Date, _ settings: MyDayDeliverySettings, context: MyDayDeliveryContext? = nil,
                        evening: String = "", checkIn: String = "") -> MyDayDeliveryDecision {
        MyDayDeliveryPolicy.decide(now: now, calendar: calendar, settings: settings,
                                   context: context ?? self.context(),
                                   lastMorningDayKey: "", lastEveningDayKey: evening, lastCheckInDayKey: checkIn)
    }

    // MARK: Its own slot

    func testTheCheckInIsOffByDefault() {
        let defaults = MyDayDeliverySettings(
            myDayEnabled: true, morningEnabled: false, morningMinutes: 8 * 60, eveningEnabled: false,
            eveningMinutes: 19 * 60, scheduledSpeechEnabled: true, quietHoursEnabled: false,
            quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60)
        XCTAssertFalse(defaults.checkInEnabled)
        XCTAssertEqual(defaults.resolvedCheckInMinutes, 21 * 60)
        XCTAssertEqual(decide(date(21, 5), defaults), .notDue)
    }

    func testTheCheckInFiresAtItsTimeInsideTheWindow() {
        XCTAssertEqual(decide(date(20, 59), settings()), .notDue)
        XCTAssertEqual(decide(date(21, 5), settings()), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
        XCTAssertEqual(decide(date(23, 0), settings()), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
        XCTAssertEqual(decide(date(23, 1), settings()), .notDue, "past the 120-minute window")
    }

    func testThePolicyNeverDeliversTwiceForOneDayKey() {
        var lastCheckIn = ""
        var lastEvening = ""
        var deliveries = 0
        let both = settings(evening: true, eveningMinutes: 20 * 60 + 45)
        for minute in stride(from: 19 * 60, through: 23 * 60 + 59, by: 1) {
            let decision = decide(date(minute / 60, minute % 60), both, evening: lastEvening, checkIn: lastCheckIn)
            guard case .deliver(let slot, let key, _, let also) = decision else { continue }
            deliveries += 1
            for delivered in [slot] + (also.map { [$0] } ?? []) {
                switch delivered {
                case .checkIn: lastCheckIn = key
                case .evening: lastEvening = key
                case .morning: XCTFail("morning is off")
                }
            }
        }
        XCTAssertEqual(deliveries, 1, "one delivery: the check-in and the evening together")
        XCTAssertEqual(lastCheckIn, dayKey)
        XCTAssertEqual(lastEvening, dayKey)
        XCTAssertEqual(decide(date(21, 30), settings(), checkIn: dayKey), .notDue)
    }

    func testQuietHoursDeferTheCheckInWithoutConsumingIt() {
        let late = settings(at: 22 * 60 + 30, quiet: true)
        XCTAssertEqual(decide(date(22, 35), late), .deferred(.quietHours))
        XCTAssertEqual(decide(date(21, 5), settings(quiet: true)), .deliver(slot: .checkIn, dayKey: dayKey, speak: true),
                       "21:00 is before the default 22:00 quiet hours")
    }

    // MARK: Merging with the evening briefing (decision 1)

    func testTheEveningAndTheCheckInMergeInsideThirtyMinutes() {
        let thirty = settings(evening: true, eveningMinutes: 20 * 60 + 30)
        XCTAssertEqual(decide(date(20, 30), thirty),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: true, alsoDelivers: .evening),
                       "the evening comes due first and brings the check-in with it, list first")

        let after = settings(evening: true, eveningMinutes: 21 * 60 + 30)
        XCTAssertEqual(decide(date(21, 0), after),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: true, alsoDelivers: .evening),
                       "a check-in before the evening slot carries it too")
    }

    func testTheyDoNotMergeAtThirtyOneMinutes() {
        let apart = settings(evening: true, eveningMinutes: 20 * 60 + 29)
        XCTAssertEqual(decide(date(20, 29), apart), .deliver(slot: .evening, dayKey: dayKey, speak: true))
        XCTAssertEqual(decide(date(21, 0), apart, evening: dayKey), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
    }

    func testAnEveningAlreadyDeliveredIsNotRepeatedByTheCheckIn() {
        let close = settings(evening: true, eveningMinutes: 20 * 60 + 45)
        XCTAssertEqual(decide(date(21, 0), close, evening: dayKey), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
    }

    func testAPartnerPastItsOwnWindowIsNotCarriedAlong() {
        // Evening 19:00 never went (the app was not running); the check-in at 19:30 is still in its
        // window at 21:15, the evening is not.
        let close = settings(at: 19 * 60 + 30, evening: true, eveningMinutes: 19 * 60)
        XCTAssertEqual(decide(date(21, 15), close), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
    }

    // MARK: Field Assist (decision 9)

    func testWithFieldAssistOnTheDefaultTimeIsFivePM() {
        let field = settings(fieldAssist: true)
        XCTAssertEqual(field.resolvedCheckInMinutes, 17 * 60)
        XCTAssertEqual(decide(date(16, 59), field), .notDue)
        XCTAssertEqual(decide(date(17, 5), field), .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
        XCTAssertEqual(decide(date(17, 5), settings()), .notDue, "without Field Assist it waits for 21:00")
    }

    func testAChosenTimeIsKeptWhateverFieldAssistDoes() {
        XCTAssertEqual(settings(at: 18 * 60, fieldAssist: true).resolvedCheckInMinutes, 18 * 60)
        XCTAssertEqual(settings(at: 18 * 60, fieldAssist: false).resolvedCheckInMinutes, 18 * 60)
        XCTAssertEqual(MyDayCheckInDefaults.minutes(fieldAssistOn: false), 21 * 60)
        XCTAssertEqual(MyDayCheckInDefaults.minutes(fieldAssistOn: true), 17 * 60)
    }

    // MARK: Driving (decision 10)

    func testAnAutomotiveReadingShowsTheCheckInAndSpeaksNothing() {
        XCTAssertEqual(decide(date(21, 5), settings(), context: context(motion: .automotive)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: false))
        XCTAssertEqual(decide(date(21, 5), settings(), context: context(motion: .walking)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
        XCTAssertEqual(decide(date(21, 5), settings(), context: context(motion: nil)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: true))
    }

    func testDrivingHoldsAMergedCheckInsSpeechToo() {
        let merged = settings(evening: true, eveningMinutes: 20 * 60 + 45)
        XCTAssertEqual(decide(date(21, 0), merged, context: context(motion: .automotive)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: false, alsoDelivers: .evening))
    }

    func testTheDrivingRuleIsTheCheckInsOnly() {
        let eveningOnly = settings(checkIn: false, evening: true)
        XCTAssertEqual(decide(date(19, 5), eveningOnly, context: context(motion: .automotive)),
                       .deliver(slot: .evening, dayKey: dayKey, speak: true))
    }

    func testTheUsualSpeechRulesStillApply() {
        XCTAssertEqual(decide(date(21, 5), settings(), context: context(presence: .away)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: false))
        XCTAssertEqual(decide(date(21, 5), settings(speech: false)),
                       .deliver(slot: .checkIn, dayKey: dayKey, speak: false))
    }

    // MARK: Stored settings

    func testTheStoredTimeFollowsTheDefaultUntilChosen() {
        let previous = UserDefaults.standard.object(forKey: "myDayCheckInMinutes")
        defer { UserDefaults.standard.set(previous, forKey: "myDayCheckInMinutes") }
        Config.myDayCheckInMinutes = nil
        XCTAssertNil(Config.myDayCheckInMinutes)
        Config.myDayCheckInMinutes = 18 * 60 + 15
        XCTAssertEqual(Config.myDayCheckInMinutes, 18 * 60 + 15)
        Config.myDayCheckInMinutes = 99 * 60
        XCTAssertEqual(Config.myDayCheckInMinutes, 23 * 60 + 59, "bounded to the day")
        Config.myDayCheckInMinutes = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: "myDayCheckInMinutes"))
    }
}
