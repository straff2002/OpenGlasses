import XCTest
@testable import OpenGlasses

/// The day the OpenAI voice stops, and the Settings line that says so beforehand.
final class OpenAIVoiceRetirementTests: XCTestCase {
    private let instant = OpenAIVoiceRetirement.retirementInstant

    func testTheInstantIsMidnightUTCOnTheSixthOfJanuary2027() {
        XCTAssertEqual(instant, ISO8601DateFormatter().date(from: "2027-01-06T00:00:00Z"))
    }

    /// One date in two places, so a change to either is caught.
    func testTheDateIsTheOneTheShutdownCalendarLists() {
        XCTAssertEqual(ModelShutdownCalendar.shutdown(provider: .openai, id: CloudVoiceRequests.openAISpeechModel),
                       OpenAIVoiceRetirement.shutdown)
    }

    func testAMinuteBeforeTheInstantItIsStillAnnounced() {
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: instant.addingTimeInterval(-60)),
                       .announced(daysLeft: 1))
    }

    func testAtTheInstantItIsRetired() {
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: instant), .retired)
    }

    func testAfterTheInstantItIsRetired() {
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: instant.addingTimeInterval(86_400 * 30)), .retired)
    }

    func testDaysLeftCountsWholeDaysUp() {
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: instant.addingTimeInterval(-86_400 * 10)),
                       .announced(daysLeft: 10))
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: instant.addingTimeInterval(-86_400 * 10 - 1)),
                       .announced(daysLeft: 11))
    }

    /// In a zone ahead of UTC it is already the 6th on the wall clock at 11:00 on a phone in
    /// Auckland, but the instant has not been reached until 13:00 there.
    func testAZoneAheadOfUTCFollowsTheInstantNotTheWallClock() throws {
        let auckland = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = auckland
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 6, hour: 11)))
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 6, hour: 13)))
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: morning), .announced(daysLeft: 1))
        XCTAssertEqual(OpenAIVoiceRetirement.phase(now: afternoon), .retired)
    }

    // MARK: - The Settings line

    func testTheFooterNamesTheDateWhileTheVoiceStillAnswers() {
        let detail = TTSEnginePreference.openAI.detail(now: instant.addingTimeInterval(-86_400))
        XCTAssertTrue(detail.hasPrefix("Prefer the OpenAI cloud voice"))
        XCTAssertTrue(detail.contains("OpenAI is retiring this voice on"))
        XCTAssertTrue(detail.contains(OpenAIVoiceRetirement.shutdown.displayDate))
    }

    func testTheFooterDropsTheLineOnceTheDateHasPassed() {
        let detail = TTSEnginePreference.openAI.detail(now: instant)
        XCTAssertTrue(detail.hasPrefix("Prefer the OpenAI cloud voice"))
        XCTAssertFalse(detail.contains("retiring"))
    }

    func testNoOtherVoiceMentionsIt() {
        for preference in TTSEnginePreference.allCases where preference != .openAI {
            XCTAssertFalse(preference.detail(now: instant.addingTimeInterval(-60)).contains("retiring"),
                           "\(preference)")
        }
    }
}
