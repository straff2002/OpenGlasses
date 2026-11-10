import XCTest
@testable import OpenGlasses

/// Plan KZ §4: a refusal that names search, remembered per account; a failure inside a turn
/// starts a 10-minute cool-off.
final class ProviderSearchRefusalTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ProviderSearchRefusalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Classifying

    func testRefusalsThatNameSearch() {
        // Anthropic: an administrator turned web search off (a 400 invalid_request_error).
        XCTAssertEqual(ProviderSearchRefusal.classify(status: 400,
                                                      message: "Web search is not enabled for this organization."),
                       .searchDisabled)
        // OpenRouter: a workspace that locks its engines answers 403.
        XCTAssertEqual(ProviderSearchRefusal.classify(status: 403,
                                                      message: "The web search engine 'native' is not allowed in this workspace"),
                       .workspaceLocked)
        // A model or endpoint that does not take the tool.
        XCTAssertEqual(ProviderSearchRefusal.classify(status: 400,
                                                      message: "Hosted tool 'web_search' is not supported with gpt-4.1-nano."),
                       .toolUnsupported)
        XCTAssertEqual(ProviderSearchRefusal.classify(status: 400, message: "tools.0.user_location.country: invalid"),
                       .toolUnsupported)
    }

    func testRefusalsThatDoNotNameSearchAreLeftAlone() {
        XCTAssertNil(ProviderSearchRefusal.classify(status: 400, message: "max_tokens: too large"))
        XCTAssertNil(ProviderSearchRefusal.classify(status: 404, message: "model not found"))
        // Authentication, rate limits and server errors behave as they always have.
        XCTAssertNil(ProviderSearchRefusal.classify(status: 401, message: "web search requires a key"))
        XCTAssertNil(ProviderSearchRefusal.classify(status: 429, message: "web_search rate limited"))
        XCTAssertNil(ProviderSearchRefusal.classify(status: 500, message: "web search failed"))
        XCTAssertNil(ProviderSearchRefusal.classify(status: 400, message: nil))
    }

    // MARK: - Remembering

    func testARefusalIsRememberedPerAccountUntilTheKeyChanges() {
        let memory = ProviderSearchMemory(defaults: defaults)
        memory.noteRefusal(.searchDisabled, provider: .anthropic, credential: "sk-ant-one", model: "claude-a")
        XCTAssertEqual(memory.reading(provider: .anthropic, credential: "sk-ant-one", model: "claude-b"),
                       .refused(.searchDisabled), "an account refusal covers every model")
        XCTAssertEqual(memory.reading(provider: .anthropic, credential: "sk-ant-two", model: "claude-a"), .clear,
                       "a new key is a new account")
        // Persisted: a fresh instance over the same store reads it.
        XCTAssertEqual(ProviderSearchMemory(defaults: defaults)
                        .reading(provider: .anthropic, credential: "sk-ant-one", model: "claude-a"),
                       .refused(.searchDisabled))
        // A refusal under the new key forgets the old key's.
        memory.noteRefusal(.searchDisabled, provider: .anthropic, credential: "sk-ant-two", model: "claude-a")
        XCTAssertEqual(memory.reading(provider: .anthropic, credential: "sk-ant-one", model: "claude-a"), .clear)
    }

    func testAModelRefusalIsKeptForThatModelOnly() {
        let memory = ProviderSearchMemory(defaults: defaults)
        memory.noteRefusal(.toolUnsupported, provider: .openai, credential: "sk-o", model: "gpt-4.1-nano")
        XCTAssertEqual(memory.reading(provider: .openai, credential: "sk-o", model: "gpt-4.1-nano"), .refused(.toolUnsupported))
        XCTAssertEqual(memory.reading(provider: .openai, credential: "sk-o", model: "gpt-5.4"), .clear)
        XCTAssertEqual(memory.latestRefusal(provider: .openai, credential: "sk-o"), .toolUnsupported)
    }

    func testTheStoreHoldsNoCredential() {
        let memory = ProviderSearchMemory(defaults: defaults)
        memory.noteRefusal(.searchDisabled, provider: .anthropic, credential: "sk-ant-secret-value", model: "m")
        let stored = defaults.dictionary(forKey: ProviderSearchMemory.defaultsKey) ?? [:]
        XCTAssertFalse(stored.keys.contains { $0.contains("secret") })
        XCTAssertTrue(stored.keys.allSatisfy { $0.hasPrefix("anthropic|") })
    }

    func testAFailedSearchCoolsOffForTenMinutes() {
        var now = Date(timeIntervalSince1970: 1_000)
        let memory = ProviderSearchMemory(defaults: defaults, now: { now })
        memory.noteInTurnFailure(provider: .xai, credential: "xai-key")
        XCTAssertEqual(memory.reading(provider: .xai, credential: "xai-key", model: "grok-4.7"), .coolingOff)
        now = now.addingTimeInterval(9 * 60)
        XCTAssertEqual(memory.reading(provider: .xai, credential: "xai-key", model: "grok-4.7"), .coolingOff)
        now = now.addingTimeInterval(61)
        XCTAssertEqual(memory.reading(provider: .xai, credential: "xai-key", model: "grok-4.7"), .clear)
        // The cool-off is not persisted.
        memory.noteInTurnFailure(provider: .xai, credential: "xai-key")
        XCTAssertEqual(ProviderSearchMemory(defaults: defaults, now: { now })
                        .reading(provider: .xai, credential: "xai-key", model: "grok-4.7"), .clear)
    }

    func testTheSwitchLineSaysWhy() {
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .ourTool(.refusedEarlier(.searchDisabled)), provider: .anthropic),
                       "Your Anthropic organisation has web search turned off, so Avenkin's search is used.")
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .ourTool(.wearerChoseEngine("Perplexity")), provider: .anthropic),
                       "Using your Perplexity key.")
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .ourTool(.unsupported), provider: .deepseek),
                       "This model can't search for itself, so Avenkin's search is used.")
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .provider(ProviderSearchSpec(provider: .anthropic, kind: .anthropic)),
                                                     provider: .anthropic),
                       "Claude runs its own searches: about $10 per 1,000 searches, billed by Anthropic.")
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .provider(ProviderSearchSpec(provider: .xai, kind: .xaiResponses)),
                                                     provider: .xai),
                       "Grok runs its own searches: about $5 per 1,000 searches, billed by xAI.")
        XCTAssertTrue(ProviderSearchStatusLine.line(for: .provider(ProviderSearchSpec(provider: .gemini, kind: .gemini)),
                                                    provider: .gemini).contains("$14 per 1,000 searches after 5,000 free a month"))
        XCTAssertEqual(ProviderSearchStatusLine.line(for: .ourTool(.unsupported), provider: .local),
                       "On-device models use Avenkin's search.")
    }

    func testFees() {
        XCTAssertEqual(SearchFeeTable.cost(kind: .anthropic, searches: 3) ?? 0, 0.03, accuracy: 1e-9)
        XCTAssertEqual(SearchFeeTable.cost(kind: .xaiResponses, searches: 2) ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertEqual(SearchFeeTable.cost(kind: .openRouter, model: "anthropic/claude-sonnet-5.5", searches: 1) ?? 0,
                       0.01, accuracy: 1e-9)
        XCTAssertNil(SearchFeeTable.cost(kind: .groq, searches: 5), "no published figure")
        XCTAssertNil(SearchFeeTable.cost(kind: .anthropic, searches: 0))
        XCTAssertEqual(SearchFeeTable.formatted(10), "$10")
        XCTAssertEqual(SearchFeeTable.formatted(7.5), "$7.50")
    }
}
