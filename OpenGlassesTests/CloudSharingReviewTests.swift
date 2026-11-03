import XCTest
@testable import OpenGlasses

/// Asking when a service is set up, so an answer given with the phone in hand is there when a
/// request arrives from Siri, the Watch or a locked phone.
@MainActor
final class CloudSharingReviewTests: XCTestCase {
    private var directory: URL!
    private var store: ConsentStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private let openAI = URL(string: "https://api.openai.com/v1/responses")!
    private let anthropic = URL(string: "https://api.anthropic.com/v1/messages")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ConsentStore(directory: directory)
        suite = "CloudSharingReviewTests"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeConsent(foreground: Bool = true) -> CloudProcessingConsent {
        let consent = CloudProcessingConsent(store: store, defaults: defaults, foreground: { foreground })
        consent.presenterAvailable = true
        return consent
    }

    private func makeService(_ name: String, _ url: String, _ scopes: CloudProcessingScope...,
                         asked: Bool = true) -> CloudService {
        CloudServiceCatalog.services(routes: scopes.map {
            CloudServiceRoute(name: name, url: url, scope: $0, asked: asked)
        })[0]
    }

    private func refusal(_ consent: CloudProcessingConsent, _ url: URL,
                         _ scope: CloudProcessingScope) async -> CloudProcessingRefusal? {
        do { _ = try await consent.authorize(url: url, scope: scope); return nil }
        catch { return error as? CloudProcessingRefusal }
    }

    /// Runs a review to the end, answering each question it shows.
    private func review(_ consent: CloudProcessingConsent, _ services: [CloudService],
                        answer: Bool = true) async -> [CloudProcessingConsent.Prompt] {
        let review = CloudSharingReview(consent: consent, services: { services }, settled: { true })
        let running = Task { await review.review() }
        let answering = Task { @MainActor () -> [CloudProcessingConsent.Prompt] in
            var asked: [CloudProcessingConsent.Prompt] = []
            while !Task.isCancelled {
                if let prompt = consent.pending {
                    asked.append(prompt)
                    consent.respond(allow: answer)
                }
                await Task.yield()
            }
            return asked
        }
        await running.value
        answering.cancel()
        return await answering.value
    }

    // MARK: Hands-free

    func testAFirstRequestWithNobodyThereIsStillRefusedForEveryUse() async {
        let locked = makeConsent(foreground: false)
        for scope in CloudProcessingScope.allCases {
            let refused = await refusal(locked, openAI, scope)
            XCTAssertEqual(refused.map { "\($0)" }, "permissionRequired", "\(scope)")
            XCTAssertNil(locked.pending, "nothing is left waiting for a person")
        }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testAnApprovalGivenAtSetupReachesAHandsFreeRequestForEachUse() async {
        let service = makeService("OpenAI", "https://api.openai.com/v1/responses", .conversation, .speechRecognition)
        _ = await review(makeConsent(), [service])
        let locked = makeConsent(foreground: false)
        let conversation = await refusal(locked, openAI, .conversation)
        let dictation = await refusal(locked, URL(string: "https://api.openai.com/v1/audio/transcriptions")!, .speechRecognition)
        XCTAssertNil(conversation)
        XCTAssertNil(dictation)
    }

    // MARK: One question per service

    func testAServiceWithTwoUsesIsOneQuestion() async {
        let asked = await review(makeConsent(), [makeService("OpenAI", "https://api.openai.com", .conversation, .speechOutput)])
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.scopes, [.conversation, .speechOutput])
        XCTAssertEqual(asked.first?.serviceName, "OpenAI")
    }

    func testAnsweredServicesAreLeftAloneAndOnlyTheNewOneIsAsked() async {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        let claude = makeService("Anthropic", "https://api.anthropic.com", .conversation)
        _ = await review(makeConsent(), [open])
        let asked = await review(makeConsent(), [open, claude])
        XCTAssertEqual(asked.map(\.serviceName), ["Anthropic"])
    }

    func testAnotherUseOfAnApprovedServiceIsAskedAbout() async {
        _ = await review(makeConsent(), [makeService("OpenAI", "https://api.openai.com", .conversation)])
        let asked = await review(makeConsent(), [makeService("OpenAI", "https://api.openai.com", .conversation, .speechOutput)])
        XCTAssertEqual(asked.first?.scopes, [.speechOutput])
    }

    // MARK: Not now

    func testNotNowIsRememberedAcrossLaunchesAndSendsNothing() async {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        let first = await review(makeConsent(), [open], answer: false)
        XCTAssertEqual(first.count, 1)
        let second = await review(makeConsent(), [open])
        XCTAssertTrue(second.isEmpty, "a new launch must not ask again")
        XCTAssertTrue(store.records.filter { !$0.isWithdrawn }.isEmpty)
    }

    func testNotNowStillAsksWhenTheServiceIsUsedOnALaterLaunch() async {
        _ = await review(makeConsent(), [makeService("OpenAI", "https://api.openai.com", .conversation)], answer: false)
        let later = makeConsent()
        let request = Task { await refusal(later, openAI, .conversation) }
        while later.pending == nil { await Task.yield() }
        later.respond(allow: true)
        let refused = await request.value
        XCTAssertNil(refused, "the first-use question stays as the safety net")
    }

    func testPickingAServiceAgainReopensNotNow() async {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        let consent = makeConsent()
        _ = await review(consent, [open], answer: false)
        XCTAssertTrue(consent.scopesToAsk(open).isEmpty)
        XCTAssertEqual(consent.scopesToAsk(open, forced: true), [.conversation])
    }

    // MARK: Withdrawal

    func testAWithdrawnServiceIsNotAskedAboutUntilItIsPickedAgain() async throws {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        let consent = makeConsent()
        _ = await review(consent, [open])
        consent.withdraw(try XCTUnwrap(consent.approval(open, scope: .conversation)))
        XCTAssertTrue(consent.scopesToAsk(open).isEmpty)
        XCTAssertEqual(consent.scopesToAsk(open, forced: true), [.conversation])
    }

    // MARK: A refused request

    func testARefusedRequestIsAskedAboutOnTheNextOpenEvenIfTheListMissesIt() async {
        let gateway = URL(string: "wss://gateway.example.test:8443/socket")!
        _ = await refusal(makeConsent(foreground: false), gateway, .conversation)
        let asked = await review(makeConsent(), [])
        XCTAssertEqual(asked.first?.terms.origin, "https://gateway.example.test:8443")
        XCTAssertEqual(asked.first?.serviceName, "gateway.example.test:8443")
        let locked = await refusal(makeConsent(foreground: false), gateway, .conversation)
        XCTAssertNil(locked)
        let again = await review(makeConsent(), [])
        XCTAssertTrue(again.isEmpty, "answered, so the queue is empty")
    }

    func testARefusedRequestIsAskedAboutOnceEvenAfterNotNow() async {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        _ = await review(makeConsent(), [open], answer: false)
        _ = await refusal(makeConsent(foreground: false), openAI, .conversation)
        let asked = await review(makeConsent(), [open])
        XCTAssertEqual(asked.count, 1, "someone wanted it to work")
    }

    // MARK: When not to ask

    func testAZeroSetupRouteIsListedButNotAskedAbout() async {
        let asked = await review(makeConsent(), [makeService("DuckDuckGo", "https://api.duckduckgo.com", .webSearch, asked: false)])
        XCTAssertTrue(asked.isEmpty)
    }

    func testLeavingTheAppLeavesTheQuestionForNextTime() async {
        let open = makeService("OpenAI", "https://api.openai.com", .conversation)
        let claude = makeService("Anthropic", "https://api.anthropic.com", .conversation)
        let consent = makeConsent()
        let review = CloudSharingReview(consent: consent, services: { [open, claude] }, settled: { true })
        let running = Task { await review.review() }
        while consent.pending == nil { await Task.yield() }
        consent.cancelPending()
        await running.value
        XCTAssertNil(consent.pending, "the rest waits, rather than asking about the next one")
        XCTAssertEqual(consent.scopesToAsk(open), [.conversation])
    }

    func testNothingIsAskedBeforeSetupIsFinished() async {
        let consent = makeConsent()
        let review = CloudSharingReview(consent: consent, services: { [self.makeService("OpenAI", "https://api.openai.com", .conversation)] },
                                        settled: { false })
        review.run()
        await Task.yield()
        XCTAssertNil(consent.pending)
    }

    func testAPermissionPromptFromARequestCoversTheServiceQuestion() async {
        let consent = makeConsent()
        let request = Task { await refusal(consent, openAI, .conversation) }
        while consent.pending == nil { await Task.yield() }
        let asked = Task { await consent.ask(about: makeService("OpenAI", "https://api.openai.com", .conversation), scopes: [.conversation]) }
        await Task.yield()
        consent.respond(allow: true)
        let answered = await asked.value
        XCTAssertTrue(answered)
        let refused = await request.value
        XCTAssertNil(refused)
        XCTAssertNil(consent.pending)
    }

    // MARK: What the person hears

    func testASpokenRefusalNamesPermissionWhateverTheNarrationSetting() {
        let line = "I need your permission to use this service. Open Avenkin and allow it, then ask me again."
        XCTAssertEqual(ModelSwitchNarrator.failureLine(CloudProcessingRefusal.permissionRequired, narrate: true), line)
        XCTAssertEqual(ModelSwitchNarrator.failureLine(CloudProcessingRefusal.permissionRequired, narrate: false), line)
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: CloudProcessingRefusal.permissionRequired), line)
    }

    func testAnOrdinaryFailureKeepsItsLines() {
        XCTAssertEqual(ModelSwitchNarrator.failureLine(URLError(.timedOut), narrate: false), "Sorry, I encountered an error.")
        XCTAssertEqual(ModelSwitchNarrator.failureLine(URLError(.timedOut), narrate: true),
                       ModelSwitchNarrator.exhaustionPhrase(lastError: URLError(.timedOut)))
    }

    func testARefusalStillStopsTheCascade() {
        XCTAssertEqual(ModelFallbackChain.classify(CloudProcessingRefusal.permissionRequired), .terminalForTurn)
    }
}

/// The list of services, which has to name the same origins the requests are checked against.
final class CloudServiceCatalogTests: XCTestCase {
    private func model(_ provider: LLMProvider, key: String = "key", baseURL: String? = nil) -> ModelConfig {
        ModelConfig(id: UUID().uuidString, name: "Model", provider: provider.rawValue, apiKey: key,
                    model: "model", baseURL: baseURL ?? provider.defaultBaseURL)
    }

    private func origin(_ url: URL, _ scope: CloudProcessingScope) throws -> String {
        try CloudProcessingTerms(url: url, scope: scope).origin
    }

    func testRoutesToOneOriginMergeIntoOneService() {
        let services = CloudServiceCatalog.services(routes: [
            CloudServiceRoute(name: "OpenAI", url: "https://api.openai.com/v1/chat/completions", scope: .conversation),
            CloudServiceRoute(name: "OpenAI", url: "wss://api.openai.com/v1/realtime", scope: .liveSession, asked: false),
            CloudServiceRoute(name: "Deepgram", url: "wss://api.deepgram.com/v1/listen", scope: .speechRecognition)
        ])
        XCTAssertEqual(services.map(\.origin), ["https://api.openai.com", "https://api.deepgram.com"])
        XCTAssertEqual(services[0].scopes, [.conversation, .liveSession])
        XCTAssertEqual(services[0].asked, [.conversation], "only the use the person set up is asked about")
    }

    func testAnUnusableAddressIsDropped() {
        let services = CloudServiceCatalog.services(routes: [
            CloudServiceRoute(name: "Studio", url: "wss://{workspace}.example.com", scope: .liveSession),
            CloudServiceRoute(name: "Empty", url: "", scope: .conversation)
        ])
        XCTAssertTrue(services.isEmpty)
    }

    func testOnDeviceModelsAndEmptyKeysReachNothing() {
        XCTAssertNil(CloudServiceCatalog.route(for: model(.local), accountConnected: false, vertexURL: nil))
        XCTAssertNil(CloudServiceCatalog.route(for: model(.appleOnDevice), accountConnected: false, vertexURL: nil))
        XCTAssertNil(CloudServiceCatalog.route(for: model(.anthropic, key: "  "), accountConnected: false, vertexURL: nil))
    }

    func testASignInStandsInForAKey() {
        XCTAssertNotNil(CloudServiceCatalog.route(for: model(.anthropic, key: ""), accountConnected: true, vertexURL: nil))
        XCTAssertNil(CloudServiceCatalog.route(for: model(.chatgpt, key: ""), accountConnected: false, vertexURL: nil))
        XCTAssertNotNil(CloudServiceCatalog.route(for: model(.chatgpt, key: ""), accountConnected: true, vertexURL: nil))
    }

    func testACustomServerIsNamedByItsHostAndNeedsNoKey() {
        let route = CloudServiceCatalog.route(for: model(.custom, key: "", baseURL: "http://192.168.1.20:11434/v1"),
                                              accountConnected: false, vertexURL: nil)
        XCTAssertEqual(route?.name, "192.168.1.20:11434")
    }

    func testVertexIsItsRegionalHost() throws {
        let url = try XCTUnwrap(VertexAI.endpointURL(projectID: "p", region: "europe-west1", model: "m"))
        let route = try XCTUnwrap(CloudServiceCatalog.route(for: model(.geminiVertex, key: ""), accountConnected: true, vertexURL: url))
        XCTAssertEqual(CloudServiceCatalog.services(routes: [route]).first?.origin, "https://europe-west1-aiplatform.googleapis.com")
    }

    /// The approval is only worth anything if it's for the origin the request will be checked at.
    func testVoiceAndDictationRoutesMatchTheRequestsTheyStandFor() throws {
        let voices: [(TTSEngine, URL)] = [(.openAI, CloudVoiceRequests.openAISpeechURL),
                                          (.xai, CloudVoiceRequests.xaiSpeechURL),
                                          (.gemini, CloudVoiceRequests.geminiModelsURL),
                                          (.elevenLabs, URL(string: "https://api.elevenlabs.io/v1/voices")!)]
        for (engine, request) in voices {
            let route = try XCTUnwrap(CloudServiceCatalog.voiceRoute(for: engine))
            XCTAssertEqual(CloudServiceCatalog.services(routes: [route]).first?.origin, try origin(request, .speechOutput))
        }
        XCTAssertNil(CloudServiceCatalog.voiceRoute(for: .system))
        XCTAssertNil(CloudServiceCatalog.voiceRoute(for: .kokoro))
        let dictation: [(CloudDictationProvider, URL)] = [(.openAI, OpenAIDictationRequest.url),
                                                          (.deepgram, URL(string: DeepgramDictationRequest.endpoint)!)]
        for (provider, request) in dictation {
            let route = CloudServiceCatalog.dictationRoute(for: provider)
            XCTAssertEqual(CloudServiceCatalog.services(routes: [route]).first?.origin, try origin(request, .speechRecognition))
        }
    }
}
