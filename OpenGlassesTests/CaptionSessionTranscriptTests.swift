import XCTest
@testable import OpenGlasses

/// Plan KP P5 — what a kept session holds and what Share hands the share sheet: one turn per line
/// as `HH:mm  said`, the speaker's name where diarisation labelled it, the translation on the line
/// under it.
final class CaptionSessionTranscriptTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let began = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33:20 UTC

    // MARK: - The recorder

    func testAPlainCaptionIsKeptAsSaid() throws {
        var recorder = CaptionSessionRecorder(startedAt: began)
        recorder.append(text: "  The coil is iced.  ", original: nil, speaker: nil, at: began)
        let session = try XCTUnwrap(recorder.finish(at: began.addingTimeInterval(60), speakerLabel: { "S\($0)" }))
        XCTAssertEqual(session.turns, [.init(at: began, said: "The coil is iced.", translation: nil, speaker: nil)])
        XCTAssertFalse(session.translated)
        XCTAssertEqual(session.startedAt, began)
    }

    func testATranslatedCaptionKeepsTheWordsAsSpokenWithTheTranslationUnderThem() throws {
        var recorder = CaptionSessionRecorder(startedAt: began)
        recorder.append(text: "Where is the filter?", original: "¿Dónde está el filtro?", speaker: nil, at: began)
        let session = try XCTUnwrap(recorder.finish(at: began, speakerLabel: { _ in "" }))
        XCTAssertEqual(session.turns.first?.said, "¿Dónde está el filtro?")
        XCTAssertEqual(session.turns.first?.translation, "Where is the filter?")
        XCTAssertTrue(session.translated)
    }

    /// A voice named halfway through carries its name on every line it spoke.
    func testSpeakersAreNamedAsTheRegistryNamesThemWhenTheSessionEnds() throws {
        var recorder = CaptionSessionRecorder(startedAt: began)
        recorder.append(text: "Hello", original: nil, speaker: 1, at: began)
        recorder.append(text: "Hi", original: nil, speaker: 2, at: began.addingTimeInterval(5))
        let names = [1: "Ana"]
        let session = try XCTUnwrap(recorder.finish(at: began) { names[$0] ?? "Speaker \($0 + 1)" })
        XCTAssertEqual(session.turns.map(\.speaker), ["Ana", "Speaker 3"])
    }

    func testNothingSaidIsNoSession() {
        var recorder = CaptionSessionRecorder(startedAt: began)
        recorder.append(text: "   ", original: nil, speaker: nil, at: began)
        XCTAssertNil(recorder.finish(at: began, speakerLabel: { _ in "" }))
    }

    func testAVeryLongSessionStopsCollectingAtTheCap() throws {
        var recorder = CaptionSessionRecorder(startedAt: began)
        for index in 0..<(CaptionSessionRecorder.turnCap + 10) {
            recorder.append(text: "line \(index)", original: nil, speaker: nil, at: began)
        }
        let session = try XCTUnwrap(recorder.finish(at: began, speakerLabel: { _ in "" }))
        XCTAssertEqual(session.turns.count, CaptionSessionRecorder.turnCap)
    }

    // MARK: - The plain text

    private func sample() -> CaptionSession {
        CaptionSession(id: UUID(), startedAt: began, endedAt: began.addingTimeInterval(900), turns: [
            .init(at: began, said: "Morning. Is the unit still tripping?", translation: nil, speaker: "Ana"),
            .init(at: began.addingTimeInterval(125), said: "Sí, cada mañana.", translation: "Yes, every morning.",
                  speaker: "Speaker 2"),
            .init(at: began.addingTimeInterval(3_700), said: "Thanks.", translation: nil, speaker: nil),
        ])
    }

    func testTheExportIsOneTurnPerLineWithTimesNamesAndTranslationsUnder() {
        let text = CaptionSessionTranscript.plainText(sample(), timeZone: utc, locale: Locale(identifier: "en_GB"))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.dropFirst(2)), [
            "07:33  Ana: Morning. Is the unit still tripping?",
            "07:35  Speaker 2: Sí, cada mañana.",
            "       Yes, every morning.",
            "08:35  Thanks.",
        ])
        XCTAssertEqual(lines[1], "", "a blank line after the heading")
    }

    func testTheHeadingSaysWhenTheSessionBeganAndWhetherItWasTranslated() {
        let heading = CaptionSessionTranscript.heading(sample(), timeZone: utc, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(heading.contains("26 October 2026"), heading)
        XCTAssertTrue(heading.contains("07:33"), heading)
        XCTAssertTrue(heading.hasPrefix("Translated captions"), heading)

        let plain = CaptionSession(id: UUID(), startedAt: began, endedAt: began,
                                   turns: [.init(at: began, said: "Hi", translation: nil, speaker: nil)])
        XCTAssertTrue(CaptionSessionTranscript.heading(plain, timeZone: utc).hasPrefix("Captions"))
    }

    /// `HH:mm` whatever the phone's locale, so the column lines up in a shared transcript.
    func testTimesAreTwentyFourHourWithLatinDigits() {
        let evening = Date(timeIntervalSince1970: 1_793_049_600)   // 2026-10-26 21:20 UTC
        XCTAssertEqual(CaptionSessionTranscript.time(evening, timeZone: utc), "21:20")
    }

    func testTheTranslationLineSitsUnderTheWords() {
        let line = CaptionSessionTranscript.line(sample().turns[0], timeZone: utc)
        let wordsStart = line.distance(from: line.startIndex, to: line.range(of: "Ana")!.lowerBound)
        XCTAssertEqual(CaptionSessionTranscript.translationIndent.count, wordsStart)
    }

    func testMentionsSearchesWordsTranslationsAndNames() {
        let session = sample()
        XCTAssertTrue(session.mentions("ana"))
        XCTAssertTrue(session.mentions("EVERY MORNING"))
        XCTAssertTrue(session.mentions("tripping"))
        XCTAssertFalse(session.mentions("compressor"))
        XCTAssertFalse(session.mentions("  "))
    }
}
