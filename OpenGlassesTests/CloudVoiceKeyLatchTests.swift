import XCTest
@testable import OpenGlasses

/// Plan KL P3: a refused voice key is asked once. Which refusals are the key's, the per-voice,
/// per-key latch and when it lets go, no request once it holds — for a spoken reply and for the
/// voice list — and the voice reading as not ready. Every request is answered locally by
/// `CloudVoiceStubURLProtocol`; key values are invented fixtures.
@MainActor
final class CloudVoiceKeyLatchTests: XCTestCase {

    private static let elevenLabsKey = "fixture-elevenlabs-voice-key"
    private static let otherElevenLabsKey = "fixture-replacement-voice-key"
    private static let geminiKey = "fixture-gemini-voice-key"
    private static let xaiToken = "fixture-xai-sign-in-token"

    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://api.elevenlabs.io",
            "https://api.x.ai",
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

    private static let unauthorized = Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)
    private static let geminiBadKey = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)

    // MARK: - Which refusals are the key's

    func testTheClassificationTable() {
        let rows: [(String, Int, String, CloudVoiceRejection?)] = [
            ("a plain 401", 401, "", .keyNotAccepted),
            ("a plain 403", 403, "", .keyNotAccepted),
            ("an ElevenLabs bad key", 401, #"{"detail":{"status":"invalid_api_key"}}"#, .keyNotAccepted),
            ("Gemini's bad key", 400, String(decoding: Self.geminiBadKey, as: UTF8.self), .keyNotAccepted),
            ("an ElevenLabs bad voice id, 404", 404, #"{"detail":{"status":"voice_not_found"}}"#, .refused),
            ("an ElevenLabs bad voice id, 400", 400, #"{"detail":{"status":"voice_not_found"}}"#, .refused),
            ("a bad voice id under a 401", 401, #"{"detail":{"status":"voice_not_found"}}"#, .refused),
            ("a plan that will not pay for the voice", 402, "", .refused),
            ("ElevenLabs out of credit", 401, #"{"detail":{"status":"quota_exceeded"}}"#, .outOfCredit),
            ("a withdrawn model", 403, #"{"error":{"code":"model_not_found"}}"#, .modelUnavailable),
            ("a withdrawn model, 404", 404, #"{"error":{"message":"The model `tts-1` has been deprecated"}}"#, .modelUnavailable),
            ("a rate limit", 429, "", nil),
            ("a server fault", 500, "", nil)
        ]
        for (name, status, body, expected) in rows {
            XCTAssertEqual(CloudVoiceRejection.classify(statusCode: status, body: body), expected, name)
        }
    }

    // MARK: - The latch

    func testTheLatchIsPerVoiceAndPerKey() {
        var latch = CloudVoiceKeyLatch()
        XCTAssertFalse(latch.isLatched(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertFalse(latch.latch(.elevenLabs, key: Self.elevenLabsKey), "a first refusal replaces nothing")
        XCTAssertTrue(latch.isLatched(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertTrue(latch.isLatched(.elevenLabs, key: " \(Self.elevenLabsKey)\n"), "read as the voice sends it")
        XCTAssertFalse(latch.isLatched(.elevenLabs, key: Self.otherElevenLabsKey), "a changed key is tried again")
        XCTAssertFalse(latch.isLatched(.openAI, key: Self.elevenLabsKey), "another voice is not latched")
        XCTAssertEqual(latch.engines, [.elevenLabs])

        XCTAssertFalse(latch.latch(.elevenLabs, key: Self.elevenLabsKey), "the same key again is not news")
        XCTAssertTrue(latch.latch(.elevenLabs, key: Self.otherElevenLabsKey), "a second bad key is news")
        XCTAssertFalse(latch.isLatched(.elevenLabs, key: Self.elevenLabsKey))

        latch.clear(.elevenLabs)
        XCTAssertFalse(latch.isLatched(.elevenLabs, key: Self.otherElevenLabsKey))
        XCTAssertTrue(latch.engines.isEmpty)
    }

    func testAnEmptyKeyIsNeverLatched() {
        var latch = CloudVoiceKeyLatch()
        XCTAssertFalse(latch.latch(.xai, key: "  "))
        XCTAssertFalse(latch.isLatched(.xai, key: ""))
        XCTAssertTrue(latch.engines.isEmpty)
    }

    /// No key material is kept: what the latch holds is a fingerprint.
    func testTheLatchHoldsNoKey() {
        var latch = CloudVoiceKeyLatch()
        latch.latch(.elevenLabs, key: Self.elevenLabsKey)
        XCTAssertFalse(String(describing: latch).contains(Self.elevenLabsKey))
        XCTAssertFalse(String(reflecting: latch).contains(Self.elevenLabsKey))
    }

    // MARK: - A spoken reply

    func testARefusedKeyIsAskedOnceThenSkippedWithNoRequest() async {
        CloudVoiceStubURLProtocol.begin(status: 401, body: Self.unauthorized)
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
            XCTFail("a 401 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.notice, CloudVoiceNotice(engine: .elevenLabs, rejection: .keyNotAccepted))
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertTrue(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertTrue(service.quotaExhausted.isEmpty, "a bad key is not an empty account")
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)

        // The next line: nothing is sent, and nothing is announced again.
        do {
            _ = try await service.fetchElevenLabsAudio(text: "And again.", apiKey: Self.elevenLabsKey)
            XCTFail("a latched key returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertNil(rejected.notice, "the refusal was told the first time")
        } catch {
            XCTFail("expected the quiet refusal, got \(error)")
        }
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1, "a latched key reached the network")

        // A different key is a new credential and is tried.
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.otherElevenLabsKey)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 2)
    }

    func testChangingTheKeyClearsTheLatchAndChangingTheVoiceDoesNot() async {
        CloudVoiceStubURLProtocol.begin(status: 401, body: Self.unauthorized)
        let service = TextToSpeechService()
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
        XCTAssertTrue(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))

        // A voice change resets the credit and model latches; the key is still the one refused.
        service.resetElevenLabsQuota()
        XCTAssertTrue(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))
        service.cloudVoiceKeyChanged(.openAI)
        XCTAssertTrue(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey), "another voice's key")

        service.cloudVoiceKeyChanged(.elevenLabs)
        XCTAssertFalse(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 2, "an edited key is tried again")
    }

    /// The wearer fixes a bad voice by picking another one, so the key must still be tried.
    func testABadVoiceIdNeverLatchesTheKey() async {
        CloudVoiceStubURLProtocol.begin(
            status: 404, body: Data(#"{"detail":{"status":"voice_not_found","message":"A voice with that id was not found."}}"#.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
            XCTFail("a 404 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.notice, CloudVoiceNotice(engine: .elevenLabs, rejection: .refused))
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertFalse(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertTrue(service.keyLatch.engines.isEmpty)
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 2)
    }

    /// A sign-in token is latched on what was sent, so it is not sent again; the token it is
    /// refreshed to is another credential.
    func testARefusedXAISignInTokenIsNotSentAgain() async {
        CloudVoiceStubURLProtocol.begin(status: 401, body: Data())
        let service = TextToSpeechService()
        _ = try? await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiToken)
        _ = try? await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiToken)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)
        _ = try? await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiToken + "-refreshed")
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 2)
    }

    // MARK: - The voice list

    func testARefusedVoiceListLatchesTheKeyForTheListAndForSpeech() async {
        CloudVoiceStubURLProtocol.begin(status: 401, body: Self.unauthorized)
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchVoiceList(.elevenLabs, key: Self.elevenLabsKey) {
                try await TextToSpeechService.fetchElevenLabsVoices(apiKey: Self.elevenLabsKey)
            }
            XCTFail("a 401 returned voices")
        } catch let refused as CloudVoiceKeyNotAccepted {
            XCTAssertEqual(refused, CloudVoiceKeyNotAccepted(engine: .elevenLabs))
            XCTAssertEqual(refused.localizedDescription, "ElevenLabs didn't accept the key")
        } catch {
            XCTFail("expected CloudVoiceKeyNotAccepted, got \(error)")
        }
        XCTAssertTrue(service.keyNotAccepted(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)

        // Opening the settings again fetches nothing, and nor does the next reply.
        do {
            _ = try await service.fetchVoiceList(.elevenLabs, key: Self.elevenLabsKey) {
                try await TextToSpeechService.fetchElevenLabsVoices(apiKey: Self.elevenLabsKey)
            }
            XCTFail("a latched key returned voices")
        } catch {
            XCTAssertTrue(error is CloudVoiceKeyNotAccepted, "\(error)")
        }
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1, "a latched key reached the network")
    }

    func testAKeyRefusedBySpeechFetchesNoVoiceList() async {
        CloudVoiceStubURLProtocol.begin(status: 400, body: Self.geminiBadKey)
        let service = TextToSpeechService()
        _ = try? await service.fetchGeminiAudio(text: "Hi.", apiKey: Self.geminiKey)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)
        var fetched = false
        do {
            _ = try await service.fetchVoiceList(.gemini, key: Self.geminiKey) { () async throws -> [String] in
                fetched = true
                return []
            }
            XCTFail("a latched key fetched a list")
        } catch {
            XCTAssertTrue(error is CloudVoiceKeyNotAccepted, "\(error)")
        }
        XCTAssertFalse(fetched)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)
    }

    func testGeminisRefusedModelListLatchesTheKey() async {
        CloudVoiceStubURLProtocol.begin(status: 400, body: Self.geminiBadKey)
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchVoiceList(.gemini, key: Self.geminiKey) {
                try await TextToSpeechService.fetchGeminiSpeechModels(apiKey: Self.geminiKey)
            }
            XCTFail("a refused key listed models")
        } catch {
            XCTAssertTrue(error is CloudVoiceKeyNotAccepted, "\(error)")
        }
        XCTAssertTrue(service.keyNotAccepted(.gemini, key: Self.geminiKey))
    }

    /// Anything that is not the key's fault fails as it always did, and latches nothing.
    func testAServerFaultOnTheVoiceListDoesNotLatch() async {
        CloudVoiceStubURLProtocol.begin(status: 500, body: Data())
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchVoiceList(.elevenLabs, key: Self.elevenLabsKey) {
                try await TextToSpeechService.fetchElevenLabsVoices(apiKey: Self.elevenLabsKey)
            }
            XCTFail("a 500 returned voices")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertNil(rejected.rejection)
            XCTAssertEqual(rejected.localizedDescription, "Cloud voice API error: 500", "the message it always had")
        } catch {
            XCTFail("expected the plain rejection, got \(error)")
        }
        XCTAssertTrue(service.keyLatch.engines.isEmpty)
    }

    // MARK: - Readiness

    func testALatchedKeyReadsAsNotReady() async {
        CloudVoiceStubURLProtocol.begin(status: 403, body: Data())
        let service = TextToSpeechService()
        XCTAssertFalse(service.isLatchedOff(.elevenLabs, key: Self.elevenLabsKey))
        _ = try? await service.fetchElevenLabsAudio(text: "Hi.", apiKey: Self.elevenLabsKey)

        XCTAssertTrue(service.isLatchedOff(.elevenLabs, key: Self.elevenLabsKey))
        XCTAssertFalse(service.isLatchedOff(.elevenLabs, key: Self.otherElevenLabsKey))
        XCTAssertFalse(service.isLatchedOff(.openAI, key: Self.elevenLabsKey))
        XCTAssertFalse(TTSEngineSelector.cloudVoiceReady(
            .elevenLabs, hasCredential: true,
            quotaExhausted: service.isLatchedOff(.elevenLabs, key: Self.elevenLabsKey),
            onDeviceOnly: false, online: true, medicalMode: .off))
        XCTAssertTrue(TTSEngineSelector.cloudVoiceReady(
            .elevenLabs, hasCredential: true,
            quotaExhausted: service.isLatchedOff(.elevenLabs, key: Self.otherElevenLabsKey),
            onDeviceOnly: false, online: true, medicalMode: .off))
    }

    // MARK: - What is said

    func testTheRowAndTheNoticeNameTheService() throws {
        XCTAssertEqual(CloudVoiceKeyLatch.settingsLine(for: .elevenLabs), "ElevenLabs didn't accept the key")
        for engine in TTSEngine.cloudVoices {
            let vendor = try XCTUnwrap(engine.vendorName)
            XCTAssertEqual(CloudVoiceKeyLatch.settingsLine(for: engine), "\(vendor) didn't accept the key")
            for nextIsCloud in [false, true] {
                var told = CloudVoiceNotice(engine: engine, rejection: .keyNotAccepted)
                told.nextIsCloud = nextIsCloud
                XCTAssertTrue(told.spokenLine.contains("\(vendor) didn't accept the key"), "\(engine)")
                XCTAssertTrue(told.banner.contains("\(vendor) didn't accept the key"), "\(engine)")
                XCTAssertFalse(told.spokenLine.contains("refused the voice request"), "\(engine)")
            }
        }
    }

    func testARefusedKeyIsAnnouncedOncePerEpisode() {
        let suite = "CloudVoiceKeyLatchTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var announcer = CloudVoiceFallbackAnnouncer(defaults: UserDefaults(suiteName: suite)!)
        let notice = CloudVoiceNotice(engine: .elevenLabs, rejection: .keyNotAccepted)
        XCTAssertEqual(notice.announcementToken, "keyNotAccepted")
        XCTAssertEqual(announcer.lineToSpeak(for: notice, plainReply: true), notice.spokenLine)
        XCTAssertNil(announcer.lineToSpeak(for: notice, plainReply: true))
        announcer.episodeEnded(for: .elevenLabs)
        XCTAssertNotNil(announcer.lineToSpeak(for: notice, plainReply: true))
    }
}
