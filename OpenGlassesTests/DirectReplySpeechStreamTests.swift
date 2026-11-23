import XCTest
@testable import OpenGlasses

/// Plan NA P1 — the reply check on a Direct turn's streamed reply: a tripping sentence is replaced
/// in the queue before it is said, the final reply (screened by the same function) reconciles with
/// nothing said twice, a hazard sentence is said and corrected, a reading number the evidence does
/// not show is withheld, a preamble is screened, and the model's history is rewritten in all three
/// message shapes.
@MainActor
final class DirectReplySpeechStreamTests: XCTestCase {

    private let scope = BlindReplyScreen.Scope(phrases: true, numbers: true)

    private func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Chunks that fall inside words, as a provider's do.
    private func chunks(_ text: String, size: Int = 7) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out
    }

    private func makeStream(_ speech: RecordingStreamedSpeech, question: String? = nil,
                            evidence: ReadingEvidence? = nil) -> DirectReplySpeechStream {
        let stream = DirectReplySpeechStream(speaker: speech)
        stream.checkReplies(with: BlindReplyScreen(surface: .direct, scope: scope, question: question),
                            evidence: { evidence })
        return stream
    }

    private func finalReply(_ reply: String, question: String? = nil,
                            evidence: ReadingEvidence? = nil) -> String {
        BlindReplyScreen.screenWhole(reply, surface: .direct, scope: scope, question: question,
                                     evidence: evidence, appLanguageIsEnglish: true).text
    }

    // MARK: - Streamed

    func testATrippingSentenceIsReplacedInTheQueueAndTheReplyReconciles() async {
        let speech = RecordingStreamedSpeech()
        let stream = makeStream(speech)
        let reply = "There's a bench on your left side. The path ahead is clear, so you can walk on. Ask me again any time you like."
        for chunk in chunks(reply) { stream.ingest(chunk) }
        XCTAssertTrue(stream.didStream)
        let screened = finalReply(reply)
        await stream.finish(reply: screened)

        let line = BlindReplyLine.safety.text(live: false)
        XCTAssertFalse(speech.played.contains { $0.contains("path ahead is clear") }, "\(speech.played)")
        XCTAssertEqual(speech.played.filter { $0 == line }.count, 1, "the line once, nothing said twice")
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(screened))
        XCTAssertEqual(screened, "There's a bench on your left side. \(line) Ask me again any time you like.")
        XCTAssertTrue(stream.preambles.isEmpty, "the reply reconciled; nothing is a separate line")
    }

    func testAHazardSentenceIsSaidThenCorrected() async {
        let speech = RecordingStreamedSpeech()
        let stream = makeStream(speech)
        let reply = "There's a kerb at one o'clock, then the way is clear. Take it slowly from here on."
        for chunk in chunks(reply) { stream.ingest(chunk) }
        let screened = finalReply(reply)
        await stream.finish(reply: screened)

        XCTAssertEqual(speech.played.first, "There's a kerb at one o'clock, then the way is clear.")
        XCTAssertEqual(speech.played.dropFirst().first, BlindReplyLine.safety.text(live: false))
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(screened))
    }

    func testAReadingNumberTheEvidenceDoesNotShowIsWithheld() async throws {
        let evidence = try XCTUnwrap(ReadingEvidence(text: "Amoxicillin take", source: .readingTool))
        let speech = RecordingStreamedSpeech()
        // Not the Blind Assistant preset: the number check runs on any turn with evidence.
        let stream = DirectReplySpeechStream(speaker: speech)
        let numbersOnly = BlindReplyScreen.Scope(phrases: false, numbers: true)
        stream.checkReplies(with: BlindReplyScreen(surface: .direct, scope: numbersOnly), evidence: { evidence })
        let reply = "The label says amoxicillin and take. It's 500 mg, twice a day with food. Hold it flat and I'll try again."
        for chunk in chunks(reply) { stream.ingest(chunk) }
        let screened = BlindReplyScreen.screenWhole(reply, surface: .direct, scope: numbersOnly, question: nil,
                                                    evidence: evidence, appLanguageIsEnglish: true).text
        await stream.finish(reply: screened)

        XCTAssertFalse(speech.played.contains { $0.contains("500") }, "\(speech.played)")
        XCTAssertTrue(speech.played.contains(BlindReplyLine.readingNumber.text(live: false)))
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(screened))
    }

    func testACleanReplyStreamsUnchanged() async {
        let speech = RecordingStreamedSpeech()
        let stream = makeStream(speech)
        let reply = "There's a bench on your left side. A door is at two o'clock, about three metres away."
        for chunk in chunks(reply) { stream.ingest(chunk) }
        let screened = finalReply(reply)
        XCTAssertEqual(screened, reply)
        await stream.finish(reply: screened)
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(reply))
    }

    func testAPreambleIsScreenedBeforeItIsSaid() async {
        let speech = RecordingStreamedSpeech()
        let stream = makeStream(speech)
        for chunk in chunks("The way ahead is clear, let me check the map for you. ") { stream.ingest(chunk) }
        stream.streamDidReset()
        XCTAssertEqual(stream.preambles, [BlindReplyLine.safety.text(live: false)])
        XCTAssertFalse(speech.played.contains { $0.contains("way ahead is clear") })
    }

    func testANoToAnObstacleQuestionIsReplaced() async {
        let speech = RecordingStreamedSpeech()
        let question = "Is anything in my way?"
        let stream = makeStream(speech, question: question)
        let reply = "No, nothing at all, carry on as you were. I'll keep watching for you."
        for chunk in chunks(reply) { stream.ingest(chunk) }
        let screened = finalReply(reply, question: question)
        await stream.finish(reply: screened)
        XCTAssertEqual(speech.played.first, BlindReplyLine.safety.text(live: false))
        XCTAssertEqual(normalised(speech.played.joined(separator: " ")), normalised(screened))
    }

    // MARK: - Whole

    func testAReplyThatDidNotStreamIsSpokenScreened() async {
        let speech = RecordingStreamedSpeech()
        let stream = makeStream(speech)
        let screened = finalReply("The path is clear.")
        await stream.finish(reply: screened)
        XCTAssertEqual(speech.wholeReplies, [BlindReplyLine.safety.text(live: false)])
    }

    // MARK: - History

    func testHistoryIsRewrittenInAllThreeShapes() {
        let original = "The path is clear, so you can walk on."
        let line = BlindReplyLine.safety.text(live: false)
        let replacements = [(original: original, replacement: line)]
        let reply = "There's a bench. \(original) Ask again."

        let plain: [[String: Any]] = [["role": "user", "content": "q"], ["role": "assistant", "content": reply]]
        let rewrittenPlain = LLMService.replacingSentencesInLastAssistant(plain, replacements: replacements)
        XCTAssertEqual(rewrittenPlain.last?["content"] as? String, "There's a bench. \(line) Ask again.")
        XCTAssertEqual(rewrittenPlain.first?["content"] as? String, "q")

        let blocks: [[String: Any]] = [["role": "assistant", "content": [["type": "text", "text": reply]]]]
        let rewrittenBlocks = LLMService.replacingSentencesInLastAssistant(blocks, replacements: replacements)
        let blockText = (rewrittenBlocks.last?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(blockText, "There's a bench. \(line) Ask again.")

        let parts: [[String: Any]] = [["role": "assistant", "parts": [["text": reply]]]]
        let rewrittenParts = LLMService.replacingSentencesInLastAssistant(parts, replacements: replacements)
        let partText = (rewrittenParts.last?["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(partText, "There's a bench. \(line) Ask again.")
    }

    func testAnEarlierAssistantMessageIsLeftAlone() {
        let original = "The path is clear."
        let history: [[String: Any]] = [
            ["role": "assistant", "content": original],
            ["role": "user", "content": "and now?"],
            ["role": "assistant", "content": "A door at two o'clock."],
        ]
        let rewritten = LLMService.replacingSentencesInLastAssistant(
            history, replacements: [(original: original, replacement: "x")])
        XCTAssertEqual(rewritten.first?["content"] as? String, original)
        XCTAssertEqual(rewritten.last?["content"] as? String, "A door at two o'clock.")
    }
}
