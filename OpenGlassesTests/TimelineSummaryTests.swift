import XCTest
@testable import OpenGlasses

/// Plan KK P1 — whether a written summary is kept, and the deterministic check that puts back the
/// figures and codes the wearer said when a summary loses them. Every job, reading and code here
/// is invented.
final class TimelineSummaryTests: XCTestCase {

    private typealias F = TimelineFixtures

    // MARK: - Acceptance

    func testAcceptanceIsMechanicalAndSaysWhy() {
        let cases: [(String, TimelineEntry.Tier, Bool, TimelineSummaryAcceptance.Verdict, String)] = [
            ("  Checked the condenser fan; it was seized.  ", .chunk, true,
             .accepted("Checked the condenser fan; it was seized."), "trimmed and kept"),
            ("   \n ", .chunk, true, .rejected(.empty), "blank"),
            ("Checked the fan and then", .chunk, false, .rejected(.cutOff), "stopped at the token limit"),
            ("Notes:\n```\nfan seized\n```", .chunk, true, .rejected(.notPlainText), "code fence"),
            ("{\"notes\": \"fan seized\"}", .chunk, true, .rejected(.notPlainText), "JSON object"),
            ("[\"fan seized\"]", .chunk, true, .rejected(.notPlainText), "JSON array"),
            (String(repeating: "a", count: 2_401), .chunk, true, .rejected(.tooLong), "over a chunk's bound"),
            (String(repeating: "a", count: 2_401), .merged, true,
             .accepted(String(repeating: "a", count: 2_401)), "within a merged entry's bound"),
            (String(repeating: "a", count: 3_201), .merged, true, .rejected(.tooLong), "over a merged bound"),
        ]
        for (text, tier, finished, expected, why) in cases {
            XCTAssertEqual(TimelineSummaryAcceptance.evaluate(text, tier: tier, finishedNormally: finished),
                           expected, why)
        }
    }

    func testABlankSummaryIsEmptyEvenWhenItWasAlsoCutOff() {
        XCTAssertEqual(TimelineSummaryAcceptance.evaluate("", tier: .chunk, finishedNormally: false),
                       .rejected(.empty))
    }

    // MARK: - Finding details

    func testMeasurementsAreFoundWithOrWithoutTheSpace() {
        let text = "Suction 52 psi, draw 3.2 A at 120V, box at -18°C and a 1/2 in line, fan at 1100 rpm."
        XCTAssertEqual(TimelineDetailCheck.details(in: text).map(\.value),
                       ["52 psi", "3.2 A", "120V", "-18°C", "1/2 in", "1100 rpm"])
        XCTAssertEqual(TimelineDetailCheck.details(in: text).map(\.normalised),
                       ["52psi", "3.2a", "120v", "-18°c", "1/2in", "1100rpm"])
    }

    func testCodesAreFoundAndOrdinaryWordsAreNot() {
        let text = "Unit LX-4410B threw E47 on the 3rd start, at 3 in the morning, 2 a day."
        let details = TimelineDetailCheck.details(in: text)
        XCTAssertEqual(details.map(\.value), ["LX-4410B", "E47"])
        XCTAssertEqual(details.map(\.kind), [.code, .code])
    }

    func testAMeasurementWrittenWithoutItsSpaceIsCountedOnce() {
        XCTAssertEqual(TimelineDetailCheck.details(in: "It reads 240V now.").map(\.kind), [.measurement])
    }

    // MARK: - Restoring what was lost

    func testALostReadingComesBackAsTheWholeSentenceWithItsTime() {
        let messages = [
            TimelineDetailCheck.Message(role: "user", text: "Okay. Suction is sitting at 52 psi. Moving on.",
                                        timestamp: F.minutes(14)),
            TimelineDetailCheck.Message(role: "assistant", text: "Noted.", timestamp: F.minutes(15)),
        ]
        let result = TimelineDetailCheck.check(summary: "Checked the suction pressure.",
                                               messages: messages, timeZone: F.utc)
        XCTAssertEqual(result.text, """
            Checked the suction pressure.

            Said word for word:
            - 09:14 "Suction is sitting at 52 psi."
            """)
        XCTAssertEqual(result.lostValues, 1)
    }

    func testAValueTheSummaryKeptIsNotRepeated() {
        let messages = [TimelineDetailCheck.Message(role: "user", text: "Draw is 3.2 A on unit LX-4410B.",
                                                    timestamp: F.start)]
        let result = TimelineDetailCheck.check(summary: "Measured 3.2A on the lx-4410b.",
                                               messages: messages, timeZone: F.utc)
        XCTAssertEqual(result.text, "Measured 3.2A on the lx-4410b.", "case and the unit's space ignored")
        XCTAssertTrue(result.restoredLines.isEmpty)
    }

    /// The summary kept the outdated value. The correction comes back whole, so the newer figure
    /// never travels without the words that make it the newer one.
    func testACorrectionKeepsItsContext() {
        let messages = [
            TimelineDetailCheck.Message(role: "user", text: "Head pressure 25 psi.", timestamp: F.minutes(2)),
            TimelineDetailCheck.Message(role: "user", text: "Sorry, I misread it: it was 52 psi, not 25.",
                                        timestamp: F.minutes(3)),
        ]
        let result = TimelineDetailCheck.check(summary: "Head pressure read 25 psi.",
                                               messages: messages, timeZone: F.utc)
        XCTAssertEqual(result.restoredLines, ["- 09:03 \"Sorry, I misread it: it was 52 psi, not 25.\""])
    }

    func testAValueIsNotFoundInsideALongerNumber() {
        let messages = [TimelineDetailCheck.Message(role: "user", text: "Line is at 52 psi.",
                                                    timestamp: F.start)]
        let result = TimelineDetailCheck.check(summary: "Line was at 152 psi.", messages: messages,
                                               timeZone: F.utc)
        XCTAssertEqual(result.lostValues, 1, "152 psi is not 52 psi")
    }

    func testOnlyTheWearersWordsAreChecked() {
        let messages = [TimelineDetailCheck.Message(role: "assistant", text: "Set it to 68°F and use part QX-210.",
                                                    timestamp: F.start)]
        let result = TimelineDetailCheck.check(summary: "Talked about the thermostat.", messages: messages,
                                               timeZone: F.utc)
        XCTAssertTrue(result.restoredLines.isEmpty)
    }

    func testOneSentenceWithTwoLostValuesIsRestoredOnce() {
        let messages = [TimelineDetailCheck.Message(role: "user", text: "Fault E47 again at 3.2 A.",
                                                    timestamp: F.start)]
        let result = TimelineDetailCheck.check(summary: "Fault came back.", messages: messages,
                                               timeZone: F.utc)
        XCTAssertEqual(result.restoredLines.count, 1)
        XCTAssertEqual(result.lostValues, 2)
    }

    func testRestoredLinesAreCappedAndKeepTheirOrder() {
        let messages = (0..<30).map {
            TimelineDetailCheck.Message(role: "user", text: "Reading \($0) is \($0 + 100) psi.",
                                        timestamp: F.minutes(Double($0)))
        }
        let result = TimelineDetailCheck.check(summary: "Took readings.", messages: messages, timeZone: F.utc)
        XCTAssertEqual(result.restoredLines.count, TimelineDetailCheck.lineLimit)
        XCTAssertEqual(result.restoredLines.first, "- 09:00 \"Reading 0 is 100 psi.\"")
        XCTAssertEqual(result.restoredLines.last, "- 09:19 \"Reading 19 is 119 psi.\"")
        XCTAssertEqual(result.lostValues, 30)
    }

    func testALongSentenceIsTrimmedAroundTheValue() {
        let filler = String(repeating: "and then we walked around the back of the building ", count: 6)
        let text = "So \(filler)before I finally read the panel at 230V while \(filler)waited."
        let messages = [TimelineDetailCheck.Message(role: "user", text: text, timestamp: F.start)]
        let line = try? XCTUnwrap(TimelineDetailCheck.check(summary: "Read the panel.", messages: messages,
                                                            timeZone: F.utc).restoredLines.first)
        XCTAssertTrue(line?.contains("230V") == true)
        XCTAssertTrue(line?.contains("…") == true)
        XCTAssertLessThan(line?.count ?? .max, 170)
    }
}
