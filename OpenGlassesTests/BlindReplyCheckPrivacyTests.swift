import XCTest
@testable import OpenGlasses

/// Plan NA §6 — the reply check never hands a sentence, a reply, a question or reading evidence to
/// `PrivacyLog`, the diagnostic ring or the support report. A source scrape over every file the
/// check lives in, and a canary run through the recorder and the tally.
@MainActor
final class BlindReplyCheckPrivacyTests: XCTestCase {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Every file the check, the guard, the watch and the tally live in, and their app glue.
    private static let files = [
        "Services/Accessibility/BlindReplyCheck.swift",
        "Services/Accessibility/BlindReplyGuard.swift",
        "Services/Accessibility/BlindReplyCheckTally.swift",
        "Services/Accessibility/LiveReplyWatch.swift",
        "Services/Accessibility/ReadingEvidence.swift",
        "Services/Accessibility/ReadingQuantityReader.swift",
        "Services/Accessibility/ReplyPhraseMechanics.swift",
        "App/AppState+BlindReplyCheck.swift",
    ]

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.sourcesRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The argument text of every `PrivacyLog.<name>(…)` call in `source`.
    private func privacyLogCalls(in source: String) -> [String] {
        var calls: [String] = []
        var search = source.startIndex
        while let start = source.range(of: "PrivacyLog.", range: search..<source.endIndex) {
            guard let open = source[start.upperBound...].firstIndex(of: "(") else { break }
            var depth = 0
            var index = open
            while index < source.endIndex {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1; if depth == 0 { break } }
                index = source.index(after: index)
            }
            calls.append(String(source[open..<min(index, source.endIndex)]))
            search = index < source.endIndex ? source.index(after: index) : source.endIndex
        }
        return calls
    }

    /// Names that hold words: a sentence, the reply, the question, the reading, a line's text.
    /// A length (`.count`) is allowed; the words are not.
    private static let contentNames = #"\b(sentence|sentences|reply|replySoFar|question|evidence|foldedText|transcript|output|text|modelNote)\b(?!\.count)"#

    func testNoLogCallInTheCheckTakesContent() throws {
        let regex = try NSRegularExpression(pattern: Self.contentNames)
        var calls = 0
        for file in Self.files {
            for call in privacyLogCalls(in: try source(file)) {
                calls += 1
                let range = NSRange(call.startIndex..., in: call)
                XCTAssertNil(regex.firstMatch(in: call, range: range), "\(file): \(call)")
            }
        }
        XCTAssertGreaterThan(calls, 0, "the scrape found the recorder's log calls")
    }

    func testTheCheckWritesNothingAnywhereElse() throws {
        for file in Self.files {
            let text = try source(file)
            for forbidden in ["DiagnosticRing", "debugContent", "print(", "NSLog(", "os_log(", "Logger(",
                              "UserDefaults", "FileManager", ".write(to:"] {
                XCTAssertFalse(text.contains(forbidden), "\(file) uses \(forbidden)")
            }
        }
    }

    func testTheTallysReportCarriesNoSentence() throws {
        let tally = try source("Services/Accessibility/BlindReplyCheckTally.swift")
        let regex = try NSRegularExpression(pattern: #"\.(sentence|replySoFar|question|foldedText|output)\b(?!\.count)"#)
        let range = NSRange(tally.startIndex..., in: tally)
        XCTAssertNil(regex.firstMatch(in: tally, range: range), "the tally reads only case names and counts")
    }

    /// The live wiring reaches the log only through the recorder.
    func testTheLiveWiringLogsOnlyThroughTheRecorder() throws {
        let manager = try source("Services/Realtime/RealtimeSessionManager.swift")
        guard let start = manager.range(of: "// MARK: - Reply check (Plan NA §5)"),
              let end = manager.range(of: "func updateAppContext", range: start.upperBound..<manager.endIndex) else {
            return XCTFail("the reply check section moved")
        }
        let section = String(manager[start.upperBound..<end.lowerBound])
        XCTAssertTrue(privacyLogCalls(in: section).isEmpty, "log through BlindReplyCheckRecorder only")
    }

    // MARK: - A canary through the recorder

    func testACanaryNeverReachesALogLineOrTheReport() throws {
        let canary = "zebracanary"
        var lines: [String] = []
        let token = PrivacyLog.addTap { _, line in lines.append(line) }
        defer { PrivacyLog.removeTap(token) }

        let evidence = try XCTUnwrap(ReadingEvidence(text: "\(canary) 200 mg", source: .readingTool))
        var screen = BlindReplyScreen(surface: .direct, scope: .init(phrases: true, numbers: true),
                                      question: "Is it safe to cross, \(canary)?")
        let items = [
            screen.screen("Yes, \(canary), the path is clear.", evidence: evidence),
            screen.screen("Take 400 mg of \(canary) now please.", evidence: evidence),
            screen.screen("I can't tell whether it's safe to cross, \(canary).", evidence: evidence),
        ]
        BlindReplyCheckRecorder.record(items, surface: .direct, provider: PrivacyToken("gemini"))
        BlindReplyCheckRecorder.recordLiveStop(provider: PrivacyToken("gemini"), pendingMilliseconds: 240, line: .safety)

        XCTAssertFalse(lines.isEmpty)
        for line in lines { XCTAssertFalse(line.lowercased().contains(canary), line) }
        for line in BlindReplyCheckRecorder.reportLines { XCTAssertFalse(line.lowercased().contains(canary), line) }
        XCTAssertTrue(lines.contains { $0.contains("[speech] replyCheck") && $0.contains("remaining=240ms") }, "\(lines)")
    }
}
