import XCTest
@testable import OpenGlasses

/// Plan JZ P0: the Gemini voice — the request's shape, both answer formats made playable, how a
/// refusal is read, and which saved key the voice uses. Key values are invented fixtures; nothing
/// reaches a server (`CloudVoiceStubURLProtocol` answers locally).
@MainActor
final class GeminiCloudVoiceTests: XCTestCase {

    private static let geminiKey = "fixture-gemini-voice-key"
    /// Four samples of 16-bit mono PCM.
    private static let pcm = Data([0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0x10, 0x00])

    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://generativelanguage.googleapis.com"
        ])
        MedicalEgressGuard.currentMode = { .off }
    }

    override func tearDown() {
        CloudVoiceStubURLProtocol.end()
        MedicalEgressGuard.currentMode = {
            MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
        }
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    /// A `generateContent` answer carrying one audio part.
    private static func answer(mimeType: String, audio: Data) -> Data {
        let body: [String: Any] = [
            "candidates": [[
                "content": ["role": "model", "parts": [["inlineData": [
                    "mimeType": mimeType, "data": audio.base64EncodedString()
                ]]]],
                "finishReason": "STOP"
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func le32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    private static func le16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    // MARK: - Request shape

    func testTheGeminiRequestPostsTheReplyToTheChosenSpeechModelWithTheKeyInAHeader() async throws {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.answer(mimeType: "audio/L16;codec=pcm;rate=24000",
                                                                       audio: Self.pcm))
        let service = TextToSpeechService()

        _ = try await service.fetchGeminiAudio(text: "Сегодня солнечно.", apiKey: Self.geminiKey)

        let seen = try XCTUnwrap(CloudVoiceStubURLProtocol.seen.first)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/\(Config.geminiTTSModel):generateContent")
        XCTAssertEqual(seen.headers["x-goog-api-key"], Self.geminiKey)
        XCTAssertEqual(seen.headers["Content-Type"], "application/json")
        XCTAssertFalse(seen.url.absoluteString.contains(Self.geminiKey), "the key is in the URL")
        XCTAssertNil(seen.url.query, "no ?key= — the chat path's habit stays out of the voice")
        XCTAssertFalse(String(decoding: seen.body, as: UTF8.self).contains(Self.geminiKey),
                       "the key is not in the body")

        let contents = try XCTUnwrap(seen.json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "Сегодня солнечно.", "the reply, in any language")
        let config = try XCTUnwrap(seen.json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
        let speech = config["speechConfig"] as? [String: Any]
        let voiceConfig = speech?["voiceConfig"] as? [String: Any]
        let voiceName = (voiceConfig?["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String
        XCTAssertEqual(voiceName, Config.geminiTTSVoice)
        XCTAssertNil(speech?["languageCode"], "the language is left to the model")
    }

    func testTheGeminiRequestOffersOnlyThePrebuiltVoices() throws {
        func voice(_ request: URLRequest) -> String? {
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let config = json?["generationConfig"] as? [String: Any]
            let speech = config?["speechConfig"] as? [String: Any]
            let voiceConfig = speech?["voiceConfig"] as? [String: Any]
            return (voiceConfig?["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String
        }
        func request(_ chosen: String) throws -> URLRequest {
            try CloudVoiceRequests.geminiSpeech(text: "Hi.", apiKey: "k", model: "gemini-3.8-flash-tts", voice: chosen)
        }
        XCTAssertEqual(voice(try request("Sulafat")), "Sulafat")
        XCTAssertEqual(voice(try request("sulafat")), "Kore", "names are exact; anything else is the default")
        XCTAssertEqual(voice(try request("")), "Kore")
        XCTAssertEqual(CloudVoiceRequests.geminiVoices.count, 30)
        XCTAssertEqual(Set(CloudVoiceRequests.geminiVoices).count, 30, "no voice twice")
        XCTAssertTrue(CloudVoiceRequests.geminiVoices.contains(CloudVoiceRequests.defaultGeminiVoice))
    }

    // MARK: - The speech model

    func testOnlyASafeSpeechModelIdReachesThePath() {
        let base = "https://generativelanguage.googleapis.com/v1beta/models/"
        XCTAssertEqual(CloudVoiceRequests.geminiSpeechURL(model: "gemini-3.8-flash-tts").absoluteString,
                       base + "gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(CloudVoiceRequests.geminiSpeechURL(model: "gemini-2.5-pro-preview-tts").absoluteString,
                       base + "gemini-2.5-pro-preview-tts:generateContent")
        for unsafe in ["gemini-3.8-flash", "gemini-3.8-flash-image", "imagen-4.0-generate-001",
                       "gemini-embedding-001", "gemini-live-2.5-flash-native-audio", "notts-model",
                       "gemini-tts/../../files", "gemini-tts?key=x", "gemini tts", "gemini-tts:streamGenerateContent",
                       "", "gemini-тts"] {
            XCTAssertFalse(CloudVoiceRequests.isGeminiSpeechModelID(unsafe), unsafe)
            XCTAssertEqual(CloudVoiceRequests.geminiSpeechURL(model: unsafe).absoluteString,
                           base + "gemini-3.8-flash-lite-tts:generateContent", "\(unsafe) is the default model")
        }
    }

    func testASavedModelThatIsNotASpeechModelReadsAsTheDefault() {
        let stored = UserDefaults.standard.string(forKey: "geminiTTSModel")
        defer { UserDefaults.standard.set(stored, forKey: "geminiTTSModel") }
        Config.setGeminiTTSModel("gemini-3.8-flash-tts")
        XCTAssertEqual(Config.geminiTTSModel, "gemini-3.8-flash-tts")
        Config.setGeminiTTSModel("gemini-3.8-flash")
        XCTAssertEqual(Config.geminiTTSModel, "gemini-3.8-flash-lite-tts", "a chat model is never the voice")
    }

    /// The key's list carries every kind of model; the picker gets the speech ones only.
    func testTheModelListOffersSpeechModelsOnly() throws {
        let body = #"""
        {"models":[
          {"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-3.8-flash-tts","displayName":"Gemini 3.8 Flash TTS","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-3.8-flash-lite-tts","displayName":" ","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-pro-preview-tts","displayName":"Gemini 2.5 Pro Preview TTS","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-flash-image","displayName":"Image","supportedGenerationMethods":["generateContent"]},
          {"name":"models/imagen-4.0-generate-001","supportedGenerationMethods":["predict"]},
          {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-live-2.5-flash-native-audio","supportedGenerationMethods":["bidiGenerateContent"]},
          {"name":"models/gemini-tts-batch-only","supportedGenerationMethods":["batchGenerateContent"]},
          {"name":"models/gemini-3.8-flash-tts","displayName":"Duplicate","supportedGenerationMethods":["generateContent"]},
          {"displayName":"No name","supportedGenerationMethods":["generateContent"]}
        ],"nextPageToken":"ignored"}
        """#
        let models = try CloudVoiceRequests.parseGeminiSpeechModels(Data(body.utf8))
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-pro-preview-tts", "gemini-3.8-flash-lite-tts",
                                          "gemini-3.8-flash-tts"])
        XCTAssertEqual(models.first(where: { $0.id == "gemini-3.8-flash-tts" })?.displayName, "Gemini 3.8 Flash TTS",
                       "the first entry of a duplicated id is kept")
        XCTAssertEqual(models.first(where: { $0.id == "gemini-3.8-flash-lite-tts" })?.displayName,
                       "gemini-3.8-flash-lite-tts", "a blank name shows the id")
        XCTAssertEqual(try CloudVoiceRequests.parseGeminiSpeechModels(Data(#"{}"#.utf8)), [])
        XCTAssertThrowsError(try CloudVoiceRequests.parseGeminiSpeechModels(Data("not json".utf8)))
    }

    func testTheModelListIsAGetWithTheKeyInAHeader() async throws {
        let body = #"{"models":[{"name":"models/gemini-3.8-flash-tts","supportedGenerationMethods":["generateContent"]}]}"#
        CloudVoiceStubURLProtocol.begin(status: 200, body: Data(body.utf8))

        let models = try await TextToSpeechService.fetchGeminiSpeechModels(apiKey: Self.geminiKey)

        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash-tts"])
        let seen = try XCTUnwrap(CloudVoiceStubURLProtocol.seen.first)
        XCTAssertEqual(seen.method, "GET")
        XCTAssertEqual(seen.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        XCTAssertEqual(seen.headers["x-goog-api-key"], Self.geminiKey)
        XCTAssertFalse(seen.url.absoluteString.contains(Self.geminiKey), "the key is in the URL")
    }

    func testARefusedModelListIsAnError() async {
        CloudVoiceStubURLProtocol.begin(status: 403, body: Data())
        do {
            _ = try await TextToSpeechService.fetchGeminiSpeechModels(apiKey: Self.geminiKey)
            XCTFail("a 403 returned models")
        } catch {}
    }

    func testAnEmptyGeminiKeyNeverReachesTheNetwork() async {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.answer(mimeType: "audio/wav", audio: Self.pcm))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchGeminiAudio(text: "Hi.", apiKey: "")
            XCTFail("an empty key was sent")
        } catch {}
        XCTAssertTrue(CloudVoiceStubURLProtocol.seen.isEmpty)
    }

    // MARK: - The answer, made playable

    func testHeaderlessPCMIsWrappedAsWAVAtItsStatedRate() throws {
        let wav = try GeminiSpeechAudio.playableAudio(
            from: Self.answer(mimeType: "audio/L16;codec=pcm;rate=24000", audio: Self.pcm))

        XCTAssertEqual(wav.count, 44 + Self.pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Self.le32(wav, at: 4), UInt32(36 + Self.pcm.count))
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(Self.le32(wav, at: 16), 16, "PCM chunk size")
        XCTAssertEqual(Self.le16(wav, at: 20), 1, "PCM")
        XCTAssertEqual(Self.le16(wav, at: 22), 1, "mono")
        XCTAssertEqual(Self.le32(wav, at: 24), 24_000)
        XCTAssertEqual(Self.le32(wav, at: 28), 48_000, "byte rate")
        XCTAssertEqual(Self.le16(wav, at: 32), 2, "block align")
        XCTAssertEqual(Self.le16(wav, at: 34), 16, "bits per sample")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(Self.le32(wav, at: 40), UInt32(Self.pcm.count))
        XCTAssertEqual(wav.suffix(Self.pcm.count), Self.pcm, "the samples untouched")
    }

    func testTheRateComesFromTheLabelElseTwentyFourKilohertz() throws {
        let named = try GeminiSpeechAudio.playable(Self.pcm, mimeType: "audio/pcm; rate=16000")
        XCTAssertEqual(Self.le32(named, at: 24), 16_000)
        let unnamed = try GeminiSpeechAudio.playable(Self.pcm, mimeType: "audio/l16")
        XCTAssertEqual(Self.le32(unnamed, at: 24), 24_000)
        let nonsense = try GeminiSpeechAudio.playable(Self.pcm, mimeType: "audio/L16;rate=fast")
        XCTAssertEqual(Self.le32(nonsense, at: 24), 24_000)
    }

    func testAHalfSampleIsDropped() throws {
        let wav = try GeminiSpeechAudio.playable(Self.pcm + Data([0x7F]), mimeType: "audio/l16")
        XCTAssertEqual(wav.count, 44 + Self.pcm.count)
        XCTAssertEqual(Self.le32(wav, at: 40), UInt32(Self.pcm.count))
    }

    func testACompleteWAVPlaysAsItCame() throws {
        let complete = GeminiSpeechAudio.wav(pcm16Mono: Self.pcm, sampleRate: 24_000)
        XCTAssertEqual(try GeminiSpeechAudio.playableAudio(from: Self.answer(mimeType: "audio/wav", audio: complete)),
                       complete)
        XCTAssertEqual(try GeminiSpeechAudio.playable(complete, mimeType: ""), complete,
                       "a RIFF body is a WAV whatever it is labelled")
    }

    func testAnAnswerWithoutPlayableAudioIsAFailureNeverAGuess() {
        func failure(_ data: Data) -> GeminiSpeechAudio.Failure? {
            do { _ = try GeminiSpeechAudio.playableAudio(from: data); return nil } catch {
                return error as? GeminiSpeechAudio.Failure
            }
        }
        let safetyStop = Data(#"{"candidates":[{"finishReason":"OTHER"}]}"#.utf8)
        XCTAssertEqual(failure(safetyStop), .noAudio)
        XCTAssertEqual(failure(Data(#"{"candidates":[]}"#.utf8)), .noAudio)
        XCTAssertEqual(failure(Data("not json".utf8)), .noAudio)
        let textOnly = Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}"#.utf8)
        XCTAssertEqual(failure(textOnly), .noAudio)
        let notBase64 = Data(#"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"audio/l16","data":"%%%"}}]}}]}"#.utf8)
        XCTAssertEqual(failure(notBase64), .undecodable)
        XCTAssertEqual(failure(Self.answer(mimeType: "audio/mpeg", audio: Data([0x49, 0x44, 0x33]))),
                       .unsupportedFormat("audio/mpeg"))
    }

    func testTheServiceReturnsPlayableWAV() async throws {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.answer(mimeType: "audio/L16;codec=pcm;rate=24000",
                                                                       audio: Self.pcm))
        let wav = try await TextToSpeechService().fetchGeminiAudio(text: "Hi.", apiKey: Self.geminiKey)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.suffix(Self.pcm.count), Self.pcm)
    }

    // MARK: - Refusals

    func testABadGeminiKeyIsNotAcceptedAndLatchesThatKey() async {
        let body = #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}"#
        CloudVoiceStubURLProtocol.begin(status: 400, body: Data(body.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchGeminiAudio(text: "Hi.", apiKey: Self.geminiKey)
            XCTFail("a 400 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.notice, CloudVoiceNotice(engine: .gemini, rejection: .keyNotAccepted))
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertTrue(service.quotaExhausted.isEmpty, "a bad key is not a spent quota")
        XCTAssertTrue(service.keyNotAccepted(.gemini, key: Self.geminiKey))
    }

    /// A 429 is a per-minute limit as often as a spent day, so it falls through this utterance and
    /// is not latched (P1 measures whether the body tells them apart).
    func testAnExhaustedGeminiQuotaFallsThroughWithoutLatching() async {
        let body = #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED"}}"#
        CloudVoiceStubURLProtocol.begin(status: 429, body: Data(body.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchGeminiAudio(text: "Hi.", apiKey: Self.geminiKey)
            XCTFail("a 429 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertNil(rejected.notice, "nothing for the wearer to fix yet")
        } catch {
            XCTFail("expected a rejection, got \(error)")
        }
        XCTAssertTrue(service.quotaExhausted.isEmpty)
    }

    func testAnOrdinaryBadRequestIsNotARefusedKey() {
        XCTAssertNil(CloudVoiceRejection.classify(
            statusCode: 400, body: #"{"error":{"code":400,"message":"Invalid JSON payload","status":"INVALID_ARGUMENT"}}"#))
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 403, body: "PERMISSION_DENIED"), .keyNotAccepted)
    }

    // MARK: - Which key the voice uses

    private func model(_ provider: LLMProvider, key: String, baseURL: String? = nil) -> ModelConfig {
        ModelConfig(id: UUID().uuidString, name: provider.rawValue, provider: provider.rawValue,
                    apiKey: key, model: "m", baseURL: baseURL ?? provider.defaultBaseURL)
    }

    func testTheGeminiVoiceUsesAGeminiModelsKeyOnGooglesOwnHost() {
        let models = [model(.anthropic, key: "anthropic-key"),
                      model(.gemini, key: ""),
                      model(.gemini, key: "proxy-key", baseURL: "https://proxy.example.com/v1beta"),
                      model(.gemini, key: " gemini-key ")]
        XCTAssertEqual(CloudVoiceCredentials.geminiKey(savedModels: models), "gemini-key",
                       "the first Gemini model with a key on Google's host, trimmed")
        XCTAssertEqual(CloudVoiceCredentials.geminiKey(savedModels: [model(.gemini, key: "k", baseURL: "")]), "k",
                       "an empty base URL is the default host")
    }

    func testAKeySavedForAnotherServerOrAVertexSignInIsNeverAGeminiVoiceKey() {
        let models = [model(.gemini, key: "proxy-key", baseURL: "https://proxy.example.com/v1beta"),
                      model(.gemini, key: "cleartext-key", baseURL: "http://generativelanguage.googleapis.com/v1beta"),
                      model(.geminiVertex, key: "vertex-key"),
                      model(.openai, key: "openai-key")]
        XCTAssertEqual(CloudVoiceCredentials.geminiKey(savedModels: models), "")
        XCTAssertEqual(CloudVoiceCredentials.geminiKey(savedModels: []), "")
    }

    // MARK: - The saved voice

    func testASavedVoiceOutsideTheListReadsAsTheDefault() {
        let stored = UserDefaults.standard.string(forKey: "geminiTTSVoice")
        defer { UserDefaults.standard.set(stored, forKey: "geminiTTSVoice") }
        Config.setGeminiTTSVoice("Puck")
        XCTAssertEqual(Config.geminiTTSVoice, "Puck")
        Config.setGeminiTTSVoice("Nobody")
        XCTAssertEqual(Config.geminiTTSVoice, "Kore")
    }
}
