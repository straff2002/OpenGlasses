import XCTest
@testable import OpenGlasses

/// Plan JM P2 — the OpenAI transcription upload: a WAV of the question, the model, the vocabulary
/// as a bounded prompt, the API key as a bearer token.
final class OpenAIDictationRequestTests: XCTestCase {

    private let boundary = "test-boundary-1234"

    func testTheRequestGoesToTheTranscriptionEndpointWithTheAPIKey() {
        let request = OpenAIDictationRequest.make(wav: Data([1, 2, 3]), apiKey: "sk-test-invented",
                                                  vocabulary: [], boundary: boundary)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-invented")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "multipart/form-data; boundary=\(boundary)")
        XCTAssertGreaterThan(request.timeoutInterval, 0)
    }

    func testTheBodyCarriesTheModelThePromptAndTheFile() throws {
        let wav = OpenAIDictationRequest.wav(samples: [0, 0.5, -0.5], sampleRate: 16_000)
        let request = OpenAIDictationRequest.make(wav: wav, apiKey: "k", vocabulary: ["XR-7720", "R-454B"],
                                                  boundary: boundary)
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"prompt\"\r\n\r\nXR-7720, R-454B\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"question.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertNotNil(body.range(of: wav), "the WAV is carried byte for byte")
    }

    func testNoVocabularyMeansNoPromptField() {
        let names = OpenAIDictationRequest.fields(vocabulary: []).map(\.name)
        XCTAssertEqual(names, ["model", "response_format"])
    }

    func testThePromptIsWholeTermsWithinTheBound() {
        let terms = (0..<500).map { "TERM-\($0)" }
        let prompt = OpenAIDictationRequest.prompt(from: ["  first ", "FIRST"] + terms)
        XCTAssertLessThanOrEqual(prompt.count, OpenAIDictationRequest.maxPromptCharacters)
        XCTAssertTrue(prompt.hasPrefix("first, TERM-0, TERM-1"), "trimmed, de-duplicated, in order")
        XCTAssertFalse(prompt.hasSuffix(","))
        for piece in prompt.components(separatedBy: ", ").dropFirst() {
            XCTAssertTrue(piece.hasPrefix("TERM-"), "never a cut term: \(piece)")
        }
    }

    func testTheWAVHeaderDescribes16BitMono() throws {
        let samples: [Float] = [0, 1, -1, 0.5]
        let wav = OpenAIDictationRequest.wav(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")

        func u16(_ offset: Int) -> UInt16 { UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(wav[offset + $1]) << (8 * UInt32($1)) }
        }
        XCTAssertEqual(u32(4), UInt32(36 + samples.count * 2), "RIFF size")
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000, "sample rate")
        XCTAssertEqual(u32(28), 32_000, "byte rate")
        XCTAssertEqual(u16(32), 2, "block align")
        XCTAssertEqual(u16(34), 16, "bits per sample")
        XCTAssertEqual(u32(40), UInt32(samples.count * 2), "data size")
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), PCMConverter.linear16(fromMono: samples))
    }

    func testTheTranscriptIsReadFromTheJSONReply() {
        XCTAssertEqual(OpenAIDictationRequest.transcript(from: Data(#"{"text":"  Check the TXV. "}"#.utf8)),
                       "Check the TXV.")
        XCTAssertNil(OpenAIDictationRequest.transcript(from: Data("not json".utf8)))
        XCTAssertNil(OpenAIDictationRequest.transcript(from: Data(#"{"error":{}}"#.utf8)))
    }

    func testTheModelIsTheCurrentRecordedSpeechModel() {
        // `gpt-4o-transcribe` goes on 2027-02-26; `gpt-transcribe` is OpenAI's named replacement.
        XCTAssertEqual(OpenAIDictationRequest.model, "gpt-transcribe")
        XCTAssertEqual(OpenAIDictationRequest.fields(vocabulary: []).first?.value, "gpt-transcribe")
    }

    func testTheTranscriptIgnoresTheLanguagesField() {
        let reply = #"{"text":" Check the TXV. ","languages":["en"],"usage":{"type":"duration","seconds":3}}"#
        XCTAssertEqual(OpenAIDictationRequest.transcript(from: Data(reply.utf8)), "Check the TXV.")
        let objects = #"{"languages":[{"language":"en","probability":0.98}],"text":"R-454B"}"#
        XCTAssertEqual(OpenAIDictationRequest.transcript(from: Data(objects.utf8)), "R-454B",
                       "whatever shape `languages` takes, only `text` is read")
    }

    // MARK: - Vocabulary spellings

    private func restored(_ text: String, _ vocabulary: [String]) -> String {
        OpenAIDictationRequest.restoringVocabularySpellings(in: text, vocabulary: vocabulary)
    }

    func testACodeWrittenWithoutItsHyphenTakesTheVocabularySpelling() {
        // What gpt-transcribe wrote on 2026-10-29 for spoken "R four fifty four B", "X R seventy seven twenty".
        XCTAssertEqual(restored("Check the TXV on the R454B unit.", ["TXV", "R-454B"]), "Check the TXV on the R-454B unit.")
        XCTAssertEqual(restored("Replace the XR7720 contactor, then the xr7720 relay.", ["XR-7720"]),
                       "Replace the XR-7720 contactor, then the XR-7720 relay.")
        XCTAssertEqual(restored("Fit SLP-99 or SLP99?", ["SLP-99"]), "Fit SLP-99 or SLP-99?")
        XCTAssertEqual(restored("The ZP54-K5E is fitted.", ["ZP-54K5E"]), "The ZP-54K5E is fitted.")
    }

    func testOnlyWholeCodeWordsChange() {
        XCTAssertEqual(restored("Top up the R32 and the R322 and the R32B.", ["R-32"]),
                       "Top up the R-32 and the R322 and the R32B.", "a longer word is a different code")
        XCTAssertEqual(restored("Check the van stock and low voltage.", ["van-stock", "low-voltage", "Copeland ZP54"]),
                       "Check the van stock and low voltage.", "words, spaced terms and letter-only terms are not codes")
        XCTAssertEqual(restored("XR15 on site.", ["XR15"]), "XR15 on site.", "a term without punctuation changes nothing")
        XCTAssertEqual(restored("", ["R-454B"]), "")
        XCTAssertEqual(restored("R454B", []), "R454B")
    }

    func testTwoSpellingsOfOneCodeAreLeftAsTranscribed() {
        XCTAssertEqual(restored("Order the AB12 part.", ["AB-12", "A-B12"]), "Order the AB12 part.")
        XCTAssertEqual(restored("Order the AB12 part.", ["AB-12", " AB-12 "]), "Order the AB-12 part.",
                       "the same spelling twice is one spelling")
    }

    func testTextInOtherScriptsPassesThrough() {
        XCTAssertEqual(restored("请检查 R454B 机组。", ["R-454B"]), "请检查 R-454B 机组。")
        XCTAssertEqual(restored("检查R454B机组", ["R-454B"]), "检查R454B机组", "not a word of its own")
    }
}
