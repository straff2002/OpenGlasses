import XCTest
@testable import OpenGlasses

/// Answers every request locally with a canned status and body, and keeps what was asked —
/// method, address, headers and body. Registered globally for the duration of one test, because
/// the speech service sends on `URLSession.shared`. Nothing reaches a server.
final class CloudVoiceStubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Seen {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [Seen] = []
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var reply = Data()

    static func begin(status: Int, body: Data) {
        lock.lock()
        requests = []
        self.status = status
        reply = body
        lock.unlock()
        URLProtocol.registerClass(CloudVoiceStubURLProtocol.self)
    }

    static func end() {
        URLProtocol.unregisterClass(CloudVoiceStubURLProtocol.self)
        lock.lock(); requests = []; lock.unlock()
    }

    static var seen: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A body set on the request reaches a protocol as a stream.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        let url = request.url ?? URL(string: "about:blank")!
        Self.requests.append(Seen(method: request.httpMethod ?? "GET", url: url,
                                  headers: request.allHTTPHeaderFields ?? [:], body: body))
        let status = Self.status
        let reply = Self.reply
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Plan ID item 5: the OpenAI and xAI voices — the shape of each request, how a refusal is read,
/// the per-voice credit latch, the xAI voice catalog, and which saved credential each voice uses.
/// Key values are invented fixtures.
@MainActor
final class CloudVoiceRequestsTests: XCTestCase {

    private static let openAIKey = "fixture-openai-voice-key"
    private static let xaiKey = "fixture-xai-voice-key"
    private static let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00])   // "ID3…", the shape of an MP3

    override func setUp() {
        super.setUp()
        MedicalEgressGuard.currentMode = { .off }
    }

    override func tearDown() {
        CloudVoiceStubURLProtocol.end()
        MedicalEgressGuard.currentMode = {
            MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
        }
        super.tearDown()
    }

    private func assertNoCredentialInTheAddress(_ seen: CloudVoiceStubURLProtocol.Seen, _ secret: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(seen.url.absoluteString.contains(secret), "the credential is in the URL", file: file, line: line)
        XCTAssertNil(seen.url.query, "no query string at all", file: file, line: line)
    }

    // MARK: - OpenAI request shape

    func testTheOpenAIRequestIsABearerPostOfTheReplyToTheSpeechEndpoint() async throws {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.audio)
        let service = TextToSpeechService()

        let data = try await service.fetchOpenAIAudio(text: "It is sunny.", apiKey: Self.openAIKey)

        XCTAssertEqual(data, Self.audio, "the audio comes back untouched")
        let seen = try XCTUnwrap(CloudVoiceStubURLProtocol.seen.first)
        XCTAssertEqual(CloudVoiceStubURLProtocol.seen.count, 1)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer \(Self.openAIKey)")
        XCTAssertEqual(seen.headers["Content-Type"], "application/json")
        assertNoCredentialInTheAddress(seen, Self.openAIKey)
        XCTAssertEqual(seen.json["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(seen.json["input"] as? String, "It is sunny.")
        XCTAssertEqual(seen.json["voice"] as? String, Config.openAITTSVoice)
        XCTAssertEqual(seen.json["response_format"] as? String, "mp3")
        XCTAssertFalse(String(decoding: seen.body, as: UTF8.self).contains(Self.openAIKey),
                       "the key is not in the body")
    }

    func testTheOpenAIRequestOffersOnlyItsPublishedVoices() throws {
        let chosen = try CloudVoiceRequests.openAISpeech(text: "Hi.", apiKey: "k", voice: "marin")
        let unknown = try CloudVoiceRequests.openAISpeech(text: "Hi.", apiKey: "k", voice: "not-a-voice")
        func voice(_ request: URLRequest) -> String? {
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            return json?["voice"] as? String
        }
        XCTAssertEqual(voice(chosen), "marin")
        XCTAssertEqual(voice(unknown), "coral", "an unknown voice falls back to the default")
        XCTAssertEqual(CloudVoiceRequests.openAIVoices.count, 13)
        XCTAssertTrue(CloudVoiceRequests.openAIVoices.contains(CloudVoiceRequests.defaultOpenAIVoice))
    }

    // MARK: - xAI request shape

    func testTheXAIRequestIsABearerPostOfTheReplyToTheSpeechEndpoint() async throws {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.audio)
        let service = TextToSpeechService()

        let data = try await service.fetchXAIAudio(text: "It is sunny.", credential: Self.xaiKey)

        XCTAssertEqual(data, Self.audio)
        let seen = try XCTUnwrap(CloudVoiceStubURLProtocol.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://api.x.ai/v1/tts")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer \(Self.xaiKey)")
        assertNoCredentialInTheAddress(seen, Self.xaiKey)
        XCTAssertEqual(seen.json["text"] as? String, "It is sunny.")
        XCTAssertEqual(seen.json["voice_id"] as? String, Config.xaiTTSVoice)
        XCTAssertEqual(seen.json["language"] as? String, "auto")
        XCTAssertEqual((seen.json["output_format"] as? [String: Any])?["codec"] as? String, "mp3")
        XCTAssertFalse(String(decoding: seen.body, as: UTF8.self).contains(Self.xaiKey))
    }

    func testAnEmptyXAIVoiceIsTheDefaultVoice() throws {
        let request = try CloudVoiceRequests.xaiSpeech(text: "Hi.", credential: "c", voice: "  ")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["voice_id"] as? String, "ara")
    }

    func testAMissingCredentialNeverReachesTheNetwork() async {
        CloudVoiceStubURLProtocol.begin(status: 200, body: Self.audio)
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchOpenAIAudio(text: "Hi.", apiKey: "")
            XCTFail("an empty key was sent")
        } catch {}
        do {
            _ = try await service.fetchXAIAudio(text: "Hi.", credential: "")
            XCTFail("an empty credential was sent")
        } catch {}
        XCTAssertTrue(CloudVoiceStubURLProtocol.seen.isEmpty)
    }

    // MARK: - Refusals and the credit latch

    func testABadOpenAIKeyIsARefusalAndDoesNotLatch() async {
        CloudVoiceStubURLProtocol.begin(
            status: 401, body: Data(#"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchOpenAIAudio(text: "Hi.", apiKey: Self.openAIKey)
            XCTFail("a 401 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.engine, .openAI)
            XCTAssertEqual(rejected.statusCode, 401)
            XCTAssertEqual(rejected.notice, CloudVoiceNotice(engine: .openAI, rejection: .refused))
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertTrue(service.quotaExhausted.isEmpty, "a bad key is not an empty account")
    }

    func testAnEmptyOpenAIAccountLatchesTheOpenAIVoiceOnly() async {
        CloudVoiceStubURLProtocol.begin(
            status: 429, body: Data(#"{"error":{"message":"You exceeded your current quota.","code":"insufficient_quota"}}"#.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchOpenAIAudio(text: "Hi.", apiKey: Self.openAIKey)
            XCTFail("a 429 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.rejection, .outOfCredit)
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertEqual(service.quotaExhausted, [.openAI])

        service.resetElevenLabsQuota()
        XCTAssertEqual(service.quotaExhausted, [.openAI], "resetting ElevenLabs leaves OpenAI's latch")
        service.resetCloudVoiceQuota(.openAI)
        XCTAssertTrue(service.quotaExhausted.isEmpty)
    }

    func testAWithdrawnModelLatchesThatVoiceOnlyAndIsNotCalledOutOfCredit() async {
        CloudVoiceStubURLProtocol.begin(
            status: 404, body: Data(#"{"error":{"message":"The model `gpt-4o-mini-tts` does not exist or you do not have access to it.","code":"model_not_found"}}"#.utf8))
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchOpenAIAudio(text: "Hi.", apiKey: Self.openAIKey)
            XCTFail("a 404 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.rejection, .modelUnavailable)
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertEqual(service.modelUnavailable, [.openAI])
        XCTAssertTrue(service.quotaExhausted.isEmpty)

        service.resetElevenLabsQuota()
        XCTAssertEqual(service.modelUnavailable, [.openAI], "resetting ElevenLabs leaves OpenAI's latch")
        service.resetCloudVoiceQuota(.openAI)
        XCTAssertTrue(service.modelUnavailable.isEmpty)
    }

    func testAPaymentRequiredFromXAIIsARefusalAndSpentCreditLatches() async {
        let service = TextToSpeechService()
        CloudVoiceStubURLProtocol.begin(status: 402, body: Data())
        do {
            _ = try await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiKey)
            XCTFail("a 402 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertEqual(rejected.notice, CloudVoiceNotice(engine: .xai, rejection: .refused))
        } catch {
            XCTFail("expected a classified rejection, got \(error)")
        }
        XCTAssertTrue(service.quotaExhausted.isEmpty)
        CloudVoiceStubURLProtocol.end()

        CloudVoiceStubURLProtocol.begin(
            status: 403, body: Data(#"{"error":"Your team has used all available credits."}"#.utf8))
        _ = try? await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiKey)
        XCTAssertEqual(service.quotaExhausted, [.xai])
    }

    func testAServerFaultIsNotTheWearersToFix() async {
        CloudVoiceStubURLProtocol.begin(status: 503, body: Data())
        let service = TextToSpeechService()
        do {
            _ = try await service.fetchXAIAudio(text: "Hi.", credential: Self.xaiKey)
            XCTFail("a 503 returned audio")
        } catch let rejected as TextToSpeechService.CloudVoiceRequestRejected {
            XCTAssertNil(rejected.notice)
        } catch {
            XCTFail("expected a rejection, got \(error)")
        }
        XCTAssertTrue(service.quotaExhausted.isEmpty)
    }

    // MARK: - xAI voice catalog

    func testTheXAIVoiceCatalogIsABearerGet() async throws {
        let body = #"{"voices":[{"voice_id":"ara","name":"Ara","gender":"female"},{"voice_id":"rex","name":"Rex"}]}"#
        CloudVoiceStubURLProtocol.begin(status: 200, body: Data(body.utf8))

        let voices = try await TextToSpeechService.fetchXAIVoices(credential: Self.xaiKey)

        XCTAssertEqual(voices.map(\.voiceId), ["ara", "rex"])
        let seen = try XCTUnwrap(CloudVoiceStubURLProtocol.seen.first)
        XCTAssertEqual(seen.method, "GET")
        XCTAssertEqual(seen.url.absoluteString, "https://api.x.ai/v1/tts/voices")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer \(Self.xaiKey)")
        assertNoCredentialInTheAddress(seen, Self.xaiKey)
    }

    func testTheXAIVoiceCatalogParserKeepsUsableEntries() throws {
        let body = #"{"voices":[{"voice_id":"ara","name":"Ara","gender":"female"},{"voice_id":"eve"},{"voice_id":" ","name":"Blank"}]}"#
        let voices = try CloudVoiceRequests.parseXAIVoices(Data(body.utf8))
        XCTAssertEqual(voices.map(\.voiceId), ["ara", "eve"], "an entry without an id is dropped")
        XCTAssertEqual(voices[0].label, "Ara — female")
        XCTAssertEqual(voices[1].label, "eve", "no name: the id is shown")
        XCTAssertThrowsError(try CloudVoiceRequests.parseXAIVoices(Data("not json".utf8)))
    }

    // MARK: - Which credential each voice uses

    private func model(_ provider: LLMProvider, key: String, baseURL: String? = nil) -> ModelConfig {
        ModelConfig(id: UUID().uuidString, name: provider.rawValue, provider: provider.rawValue,
                    apiKey: key, model: "m", baseURL: baseURL ?? provider.defaultBaseURL)
    }

    func testTheOpenAIVoiceUsesAnOpenAIModelsKeyOnOpenAIsOwnHost() {
        let models = [model(.anthropic, key: "anthropic-key"),
                      model(.openai, key: "", baseURL: nil),
                      model(.openai, key: "proxy-key", baseURL: "https://proxy.example.com/v1/chat/completions"),
                      model(.openai, key: " openai-key ")]
        XCTAssertEqual(CloudVoiceCredentials.openAIKey(savedModels: models, legacyKey: "legacy"), "openai-key",
                       "the first OpenAI model with a key on OpenAI's host, trimmed")
    }

    func testAKeySavedForAnotherServerIsNeverSentToOpenAI() {
        let models = [model(.openai, key: "proxy-key", baseURL: "https://proxy.example.com/v1/chat/completions"),
                      model(.custom, key: "custom-key"),
                      model(.groq, key: "groq-key")]
        XCTAssertEqual(CloudVoiceCredentials.openAIKey(savedModels: models, legacyKey: ""), "")
        XCTAssertEqual(CloudVoiceCredentials.openAIKey(savedModels: models, legacyKey: "legacy-key"), "legacy-key")
    }

    func testAChatGPTSignInIsNotAnOpenAIVoiceCredential() {
        let models = [model(.chatgpt, key: "")]
        XCTAssertEqual(CloudVoiceCredentials.openAIKey(savedModels: models, legacyKey: ""), "")
    }

    func testTheXAIVoiceSourcePrefersTheKeyThenTheAccount() {
        let keyed = [model(.xai, key: ""), model(.xai, key: "xai-model-key")]
        XCTAssertEqual(CloudVoiceCredentials.xaiModelKey(savedModels: keyed), "xai-model-key")
        XCTAssertEqual(CloudVoiceCredentials.xaiSource(savedModels: keyed, accountConnected: true), .modelKey)
        XCTAssertEqual(CloudVoiceCredentials.xaiSource(savedModels: [model(.xai, key: "")], accountConnected: true),
                       .account)
        XCTAssertEqual(CloudVoiceCredentials.xaiSource(savedModels: [model(.xai, key: "")], accountConnected: false),
                       .none)
        XCTAssertEqual(CloudVoiceCredentials.xaiSource(
            savedModels: [model(.xai, key: "elsewhere", baseURL: "https://other.example.com/v1")],
            accountConnected: false), .none, "a key saved for another host is not an xAI key")
    }

    func testTheResolvedXAICredentialIsTheKeyElseTheAccountTokenElseNothing() async throws {
        let response = try OAuthRefreshFixture.decode(
            XAIOAuth.TokenResponse.self, OAuthRefreshFixture.tokenBody(access: "access-fixture-voice"))
        let holder = InMemoryCredentialStore(holding: XAIOAuth.Credentials(response: response, now: Date()))
        let connected = XAIOAuthService(store: holder.store, session: OfflineURLProtocol.session(),
                                        refresher: SingleFlightRefresher(), discoversEndpoints: false)
        let signedOut = XAIOAuthService(store: InMemoryCredentialStore().store,
                                        session: OfflineURLProtocol.session(),
                                        refresher: SingleFlightRefresher(), discoversEndpoints: false)

        let keyed = [model(.xai, key: "xai-model-key")]
        let unkeyed = [model(.xai, key: "")]
        let key = await CloudVoiceCredentials.resolveXAICredential(savedModels: keyed, account: connected)
        let token = await CloudVoiceCredentials.resolveXAICredential(savedModels: unkeyed, account: connected)
        let none = await CloudVoiceCredentials.resolveXAICredential(savedModels: unkeyed, account: signedOut)
        XCTAssertEqual(key, "xai-model-key", "a typed key wins")
        XCTAssertEqual(token, "access-fixture-voice")
        XCTAssertEqual(none, "")
    }

    func testAnEmptyBaseURLIsTheVendorsOwnHost() {
        XCTAssertTrue(CloudVoiceCredentials.isHost("", "api.openai.com"))
        XCTAssertTrue(CloudVoiceCredentials.isHost("https://api.x.ai/v1/chat/completions", "x.ai"))
        XCTAssertFalse(CloudVoiceCredentials.isHost("http://api.openai.com/v1", "api.openai.com"), "cleartext")
        XCTAssertFalse(CloudVoiceCredentials.isHost("https://api.openai.com.example.net/v1", "api.openai.com"))
        XCTAssertFalse(CloudVoiceCredentials.isHost("https://notx.ai/v1", "x.ai"))
    }
}
