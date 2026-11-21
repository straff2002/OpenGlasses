import XCTest
@testable import OpenGlasses

/// A meeting summary covers the whole meeting: the caption service keeps every final of the
/// session in memory (`MeetingTranscriptBuffer`), and the tool hands the model a budgeted excerpt
/// spread across all of it (`MeetingTranscriptExcerpt`).
final class MeetingTranscriptTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func line(_ text: String, minute: Double) -> MeetingTranscriptBuffer.Line {
        .init(text: text, timestamp: start.addingTimeInterval(minute * 60))
    }

    // MARK: - Buffer

    func testTheBufferKeepsEveryLineOldestFirst() {
        var buffer = MeetingTranscriptBuffer()
        buffer.append(line("Morning everyone.", minute: 0))
        buffer.append(.init(text: "  Second item.  ", timestamp: start.addingTimeInterval(60), speaker: 2,
                            original: "Segundo punto.", language: "es"))
        buffer.append(line("   ", minute: 2))
        XCTAssertEqual(buffer.lines.map(\.text), ["Morning everyone.", "Second item."])
        XCTAssertEqual(buffer.lines[1].speaker, 2)
        XCTAssertEqual(buffer.lines[1].original, "Segundo punto.")
        XCTAssertEqual(buffer.lines[1].language, "es")
    }

    func testTheBufferIsBoundedAndCountsWhatWent() {
        var buffer = MeetingTranscriptBuffer(capacity: 3)
        for index in 0..<5 { buffer.append(line("Line \(index)", minute: Double(index))) }
        XCTAssertEqual(buffer.lines.map(\.text), ["Line 2", "Line 3", "Line 4"])
        XCTAssertEqual(buffer.dropped, 2)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.dropped, 0)
    }

    func testTheDefaultBoundIsTheKeptSessionsCap() {
        XCTAssertEqual(MeetingTranscriptBuffer().capacity, CaptionSessionRecorder.turnCap)
    }

    // MARK: - Excerpt

    private func meeting(lines count: Int, minutes: Double) -> [MeetingTranscriptExcerpt.Line] {
        (0..<count).map { index in
            .init(text: "Point \(index) about the quarterly schedule and the site visits.",
                  timestamp: start.addingTimeInterval(Double(index) / Double(max(1, count - 1)) * minutes * 60))
        }
    }

    func testAMeetingThatFitsIsSentWhole() {
        let lines = meeting(lines: 10, minutes: 9)
        let excerpt = MeetingTranscriptExcerpt.make(lines: lines, budget: 10_000, timeZone: utc)
        XCTAssertTrue(excerpt.isComplete)
        XCTAssertEqual(excerpt.lines.count, 10)
        XCTAssertEqual(excerpt.lines.first, "[08:00:00] Point 0 about the quarterly schedule and the site visits.")
        XCTAssertEqual(excerpt.header, "TRANSCRIPT (all 10 lines, 08:00–08:09):")
    }

    func testALongMeetingIsCutToTheBudgetAndSpreadAcrossAllOfIt() {
        let lines = meeting(lines: 1_980, minutes: 68)
        let budget = 6_000
        let excerpt = MeetingTranscriptExcerpt.make(lines: lines, budget: budget, timeZone: utc)
        XCTAssertFalse(excerpt.isComplete)
        XCTAssertLessThanOrEqual(excerpt.text.count, budget)
        XCTAssertGreaterThan(excerpt.text.count, budget * 3 / 4, "the budget is mostly used")
        // Lines from the first, a middle and the last stretch of the meeting, oldest first.
        let minutes = excerpt.lines.compactMap { line -> Int? in
            guard let hour = Int(line.dropFirst(1).prefix(2)), let minute = Int(line.dropFirst(4).prefix(2)) else { return nil }
            return hour * 60 + minute - 8 * 60
        }
        XCTAssertEqual(minutes.count, excerpt.lines.count)
        XCTAssertTrue(minutes.contains { $0 < 6 }, "the start is there")
        XCTAssertTrue(minutes.contains { (30...38).contains($0) }, "the middle is there")
        XCTAssertTrue(minutes.contains { $0 >= 62 }, "the end is there")
        XCTAssertEqual(minutes, minutes.sorted(), "oldest first")
        XCTAssertTrue(excerpt.header.hasPrefix("TRANSCRIPT (\(excerpt.shownCount) of 1,980 lines shown, 08:00–09:08; "),
                      excerpt.header)
        XCTAssertTrue(excerpt.header.contains("\(MeetingTranscriptExcerpt.grouped(1_980 - excerpt.shownCount)) lines left out"))
    }

    func testActionItemsAndDecisionsAreAlwaysKept() {
        var lines = meeting(lines: 600, minutes: 60)
        lines[17] = .init(text: "We agreed to move the launch to March.", timestamp: lines[17].timestamp)
        lines[333] = .init(text: "Ana will send the revised budget by Friday.", timestamp: lines[333].timestamp)
        let texts = lines.map(\.text)
        let pinned = MeetingTranscriptExcerpt.pinnedIndices(
            texts: texts, actionItems: ["Ana will send the revised budget by Friday"],
            decisions: ["We agreed to move the launch to March."])
        XCTAssertEqual(pinned, [17, 333])
        let excerpt = MeetingTranscriptExcerpt.make(lines: lines, pinned: pinned, budget: 2_500, timeZone: utc)
        XCTAssertTrue(excerpt.text.contains("We agreed to move the launch to March."))
        XCTAssertTrue(excerpt.text.contains("Ana will send the revised budget by Friday."))
        XCTAssertTrue(excerpt.allPinnedShown)
        XCTAssertTrue(excerpt.header.contains("every action-item and decision line is included"))
    }

    func testTheSelectionIsDeterministic() {
        let lines = meeting(lines: 900, minutes: 45)
        let a = MeetingTranscriptExcerpt.make(lines: lines, pinned: [3, 400], budget: 4_000, timeZone: utc)
        let b = MeetingTranscriptExcerpt.make(lines: lines, pinned: [3, 400], budget: 4_000, timeZone: utc)
        XCTAssertEqual(a, b)
    }

    func testLinesThatShareOneTimeAreCutByPosition() {
        let slices = MeetingTranscriptExcerpt.slices(Array(repeating: start, count: 24), count: 12)
        XCTAssertEqual(slices.count, 12)
        XCTAssertEqual(slices.map(\.count), Array(repeating: 2, count: 12))
    }

    func testTheBudgetFollowsTheModelsWindow() {
        XCTAssertEqual(MeetingTranscriptExcerpt.characterBudget(contextTokens: nil),
                       MeetingTranscriptExcerpt.conservativeCharacters)
        XCTAssertEqual(MeetingTranscriptExcerpt.characterBudget(contextTokens: 4_096), 3_072,
                       "a 4k on-device model gets about 750 tokens")
        XCTAssertEqual(MeetingTranscriptExcerpt.characterBudget(contextTokens: 32_768), 24_576)
        XCTAssertEqual(MeetingTranscriptExcerpt.characterBudget(contextTokens: 1_000_000),
                       MeetingTranscriptExcerpt.maximumCharacters)
        XCTAssertEqual(MeetingTranscriptExcerpt.characterBudget(contextTokens: 1_000),
                       MeetingTranscriptExcerpt.minimumCharacters)
        XCTAssertLessThanOrEqual(MeetingTranscriptExcerpt.conservativeCharacters, 3_072)
    }

    func testNumbersAreGrouped() {
        XCTAssertEqual(MeetingTranscriptExcerpt.grouped(7), "7")
        XCTAssertEqual(MeetingTranscriptExcerpt.grouped(412), "412")
        XCTAssertEqual(MeetingTranscriptExcerpt.grouped(1_980), "1,980")
        XCTAssertEqual(MeetingTranscriptExcerpt.grouped(1_234_567), "1,234,567")
    }

    func testTheDurationCoversTheWholeMeeting() {
        XCTAssertEqual(MeetingSummaryTool.duration(of: [start, start.addingTimeInterval(68 * 60)]), "1h 8m")
        XCTAssertEqual(MeetingSummaryTool.duration(of: []), "unknown")
    }
}

/// The caption service side: every final reaches the whole-session transcript, it survives stop,
/// starts empty, is cleared with the history and is never written anywhere.
@MainActor
final class AmbientCaptionMeetingTranscriptTests: XCTestCase {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    func testAVisualNoteJoinsTheTranscript() {
        let captions = AmbientCaptionService()
        captions.insertVisualNote("a whiteboard with three columns")
        XCTAssertEqual(captions.meetingTranscript.lines.map(\.text), ["[Visual: a whiteboard with three columns]"])
        captions.clearHistory()
        XCTAssertTrue(captions.meetingTranscript.isEmpty)
    }

    func testTheTranscriptOutlivesTheCappedHistory() {
        let captions = AmbientCaptionService()
        for index in 0..<120 { captions.insertVisualNote("slide \(index)") }
        XCTAssertEqual(captions.captionHistory.count, 50, "the screen's history stays capped")
        XCTAssertEqual(captions.meetingTranscript.count, 120, "the meeting keeps every line")
        XCTAssertEqual(captions.meetingTranscript.lines.first?.text, "[Visual: slide 0]")
    }

    func testTheSummaryReadsTheWholeSessionNotTheScreensHistory() async {
        let captions = AmbientCaptionService()
        for index in 0..<120 { captions.insertVisualNote("slide \(index)") }
        let tool = MeetingSummaryTool(captionService: captions)
        let output = await tool.summarize(args: ["mode": "full", "save": false])
        XCTAssertTrue(output.text.contains("Segments: 120"), output.text)
        XCTAssertTrue(output.text.contains("[Visual: slide 0]"), "the start of the meeting is in the excerpt")
        XCTAssertTrue(output.text.contains("120 lines"), "the excerpt says how much of the meeting it covers")
        XCTAssertEqual(output.facts?.transcript.components(separatedBy: "\n").count, 120)
        LatestMeetingSummary.shared.clear()
    }

    func testFinalsReachTheTranscriptOnlyThroughTheGuardedPaths() throws {
        let code = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("Services/AmbientCaptionService.swift"),
                              encoding: .utf8)
        XCTAssertEqual(code.components(separatedBy: "meetingTranscript.append(").count - 1, 2,
                       "finalizeCaption (after TranscriptGuard) and insertVisualNote, nothing else")
    }

    /// Memory only: no file names the buffer beside the caption service, the tool and its tests.
    func testTheTranscriptIsNeverWrittenDown() throws {
        let enumerator = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        let allowed: Set<String> = ["MeetingTranscriptBuffer.swift", "AmbientCaptionService.swift",
                                    "MeetingSummaryTool.swift"]
        for url in files where !allowed.contains(url.lastPathComponent) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("meetingTranscript") || text.contains("MeetingTranscriptBuffer"),
                           "\(url.lastPathComponent) reads the in-memory meeting transcript")
        }
        let buffer = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("Services/MeetingTranscriptBuffer.swift"),
                                encoding: .utf8)
        for writer in ["Codable", "FileManager", "write(to:", "UserDefaults", "PrivacyLog"] {
            XCTAssertFalse(buffer.contains(writer), "the buffer names \(writer)")
        }
    }
}
