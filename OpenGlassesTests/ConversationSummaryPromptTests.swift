import XCTest
@testable import OpenGlasses

/// The summary instruction carries today's date and asks for absolute dates, because the summary is
/// read again on later days.
final class ConversationSummaryPromptTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let auckland = TimeZone(identifier: "Pacific/Auckland")!

    /// 2026-10-31 12:00 UTC.
    private let halloweenNoonUTC = Date(timeIntervalSince1970: 1_793_448_000)

    func testTheDateIsWrittenInFull() {
        XCTAssertEqual(ConversationSummaryPrompt.dateLine(now: halloweenNoonUTC, timeZone: utc),
                       "Saturday 31 October 2026")
    }

    func testTheDateIsTheWearersDayNotUTCs() {
        // Midday UTC is already 1 November in Auckland (UTC+13 in daylight time).
        XCTAssertEqual(ConversationSummaryPrompt.dateLine(now: halloweenNoonUTC, timeZone: auckland),
                       "Sunday 1 November 2026")
    }

    func testThePromptGivesTodayAndForbidsRelativeDates() {
        let prompt = ConversationSummaryPrompt.make(transcript: "user: remind me tomorrow",
                                                    now: halloweenNoonUTC, timeZone: utc)
        XCTAssertTrue(prompt.contains("Today is Saturday 31 October 2026."))
        XCTAssertTrue(prompt.contains("Write every date as an absolute date"))
        for word in ["\"today\"", "\"tomorrow\"", "\"yesterday\"", "\"next week\""] {
            XCTAssertTrue(prompt.contains(word), "\(word) is named as a word to avoid")
        }
        XCTAssertTrue(prompt.contains("keep the speaker's words in quotes"),
                      "an unclear date is quoted, not guessed")
    }

    func testThePromptKeepsWhatItAlwaysPreserved() {
        let prompt = ConversationSummaryPrompt.make(transcript: "x", now: halloweenNoonUTC, timeZone: utc)
        for line in ["All user-stated facts, names, and preferences",
                     "Decisions made and commitments given",
                     "Tool calls and their key results",
                     "Memory commands ([REMEMBER], [FORGET])",
                     "Any unresolved questions or action items",
                     "Keep it under 300 words."] {
            XCTAssertTrue(prompt.contains(line), line)
        }
    }

    func testTheTranscriptComesLast() {
        let transcript = "user: I parked on level 3\nassistant: Noted."
        let prompt = ConversationSummaryPrompt.make(transcript: transcript, now: halloweenNoonUTC, timeZone: utc)
        XCTAssertTrue(prompt.hasSuffix("CONVERSATION:\n" + transcript))
    }
}
