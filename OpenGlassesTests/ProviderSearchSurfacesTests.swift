import XCTest
@testable import OpenGlasses

/// Plan KZ §6, §9, §10: where a provider search shows up — the conversation thread, the
/// Display's answer card, the support trace, Cloud AI Sharing and the privacy copy.
@MainActor
final class ProviderSearchSurfacesTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private let suggestions = SearchSuggestions(
        renderedContent: "<style>.c{}</style><div class=\"c\"><a href=\"https://www.google.com/search?q=shops\">shops</a></div>",
        queries: ["shops"],
        links: [.init(query: "shops", url: "https://www.google.com/search?q=shops")])

    // MARK: - The message keeps them

    func testAThreadSavedBeforeTheFieldsDecodesUnchanged() throws {
        let old = #"""
        {"id":"m1","role":"assistant","content":"Hello","imageAttached":false,"timestamp":800000000,"toolNames":["get_weather"]}
        """#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(old.utf8))
        XCTAssertEqual(message.content, "Hello")
        XCTAssertNil(message.webSources)
        XCTAssertNil(message.searchSuggestions)
        XCTAssertEqual(message.sources, [])
        // An ordinary reply adds nothing to the saved file.
        let plain = String(decoding: try JSONEncoder().encode(ConversationMessage(role: "assistant", content: "x")), as: UTF8.self)
        XCTAssertFalse(plain.contains("webSources"))
        XCTAssertFalse(plain.contains("searchSuggestions"))
    }

    func testSourcesAndSuggestionsAreStoredAndDecodedWithTheReply() throws {
        let source = WebSource(title: "Shops", url: "https://airport.example/shops", provider: "gemini")
        let message = ConversationMessage(role: "assistant", content: "Open until 9.", webSources: [source],
                                          searchSuggestions: suggestions)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.sources, [source])
        XCTAssertEqual(decoded.searchSuggestions, suggestions)
        XCTAssertEqual(decoded.searchSuggestions?.renderedContent, suggestions.renderedContent, "byte for byte")
    }

    func testTheStoreKeepsThemOnTheThreadTheQuestionWentTo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        let thread = store.startThread(mode: "direct").id
        store.appendMessage(role: "user", content: "Is it open?", toThread: thread)
        store.appendMessage(role: "assistant", content: "Yes.", webSources: [
            WebSource(title: "Shops", url: "https://airport.example/shops", provider: "gemini")],
                            searchSuggestions: suggestions, toThread: thread)
        let saved = try XCTUnwrap(store.threads.first { $0.id == thread }?.messages.last)
        XCTAssertEqual(saved.searchSuggestions, suggestions)
        XCTAssertEqual(saved.sources.count, 1)
    }

    func testTheThreadShowsThemUnderTheRightReplyOnly() {
        let question = ConversationMessage(role: "user", content: "Is it open?", webSources: [
            WebSource(title: "x", url: "https://x.example", provider: "gemini")])
        let grounded = ConversationMessage(role: "assistant", content: "Yes.", webSources: [
            WebSource(title: "Shops", url: "https://airport.example/shops", provider: "gemini")],
                                           searchSuggestions: suggestions)
        let plain = ConversationMessage(role: "assistant", content: "Anything else?")
        let byMessage = ReplyAttachments.byMessage([question, grounded, plain])
        XCTAssertEqual(Array(byMessage.keys), [grounded.id])
        XCTAssertEqual(byMessage[grounded.id]?.suggestions, suggestions)
        XCTAssertEqual(byMessage[grounded.id]?.sources.map(\.site), ["airport.example"])
        XCTAssertTrue(ReplyAttachments(message: question).isEmpty, "a user turn carries none")
    }

    // MARK: - Taps go straight to the link

    func testATappedSuggestionOpensItsOwnAddressInSafari() throws {
        let url = try XCTUnwrap(URL(string: "https://www.google.com/search?q=airport+shops&client=x"))
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .linkTapped, url: url), .openInSafari(url))
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .initialLoad, url: URL(string: "about:blank")), .allow)
        // Nothing else navigates: no redirect, no script, no other scheme.
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .other, url: url), .cancel)
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .linkTapped, url: URL(string: "javascript:alert(1)")), .cancel)
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .linkTapped, url: URL(string: "tel:123")), .cancel)
        XCTAssertEqual(SearchSuggestionsLinkPolicy.action(for: .linkTapped, url: nil), .cancel)
    }

    // MARK: - The Display

    func testTheAnswerCardLineNamesNoAddress() {
        XCTAssertNil(HUDAnswerCard.webSourcesLine(count: 0, hasSearchSuggestions: false))
        XCTAssertEqual(HUDAnswerCard.webSourcesLine(count: 1, hasSearchSuggestions: false), "1 web source on your phone")
        XCTAssertEqual(HUDAnswerCard.webSourcesLine(count: 3, hasSearchSuggestions: false), "3 web sources on your phone")
        XCTAssertEqual(HUDAnswerCard.webSourcesLine(count: 2, hasSearchSuggestions: true),
                       "2 web sources and Google search suggestions on your phone")
        XCTAssertEqual(HUDAnswerCard.webSourcesLine(count: 0, hasSearchSuggestions: true),
                       "Google search suggestions on your phone")
    }

    // MARK: - The support trace

    func testTheTraceRecordsAProviderSearchBoundedAndMasked() {
        TurnRecorder.reset(ledger: TurnLedger(), now: { Date(timeIntervalSince1970: 1_790_000_000) }, micRoutePorts: { [] })
        defer { TurnRecorder.reset() }
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        var evidence = ProviderSearchEvidence()
        evidence.addQuery("store hours sk-secret-fixture")
        evidence.searchCount = 1
        evidence.addSource(WebSource(title: "Hours", url: "https://hardware.example/h", provider: "openai"))
        evidence.addSnippet(String(repeating: "c", count: 400))
        TurnRecorder.noteProviderSearch(provider: "openai", evidence: evidence, turnID: TurnRecorder.toolTraceID,
                                        secrets: { ["sk-secret-fixture"] })
        TurnRecorder.noteProviderSearchRefused(provider: "anthropic", kind: .searchDisabled,
                                               turnID: TurnRecorder.toolTraceID)
        TurnRecorder.endTurn()
        let calls = sunk.first?.toolCalls ?? []
        XCTAssertEqual(calls.map(\.outcome), ["provider", "provider refused (searchDisabled)"])
        let search = calls.first?.search
        XCTAssertNotNil(search)
        XCTAssertFalse(search?.query.contains("sk-secret-fixture") ?? true)
        XCTAssertTrue(search?.result.contains("https://hardware.example/h") ?? false)
        XCTAssertTrue(search?.result.contains(String(repeating: "c", count: ProviderSearchEvidence.snippetLimit)) ?? false)
        XCTAssertFalse(search?.result.contains(String(repeating: "c", count: ProviderSearchEvidence.snippetLimit + 1)) ?? true)
        XCTAssertNil(calls.last?.search)
    }

    func testAProviderSearchOutsideTheTurnLeavesNoNote() {
        TurnRecorder.reset(ledger: TurnLedger(), now: { Date() }, micRoutePorts: { [] })
        defer { TurnRecorder.reset() }
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.noteProviderSearch(provider: "openai", evidence: ProviderSearchEvidence(), turnID: UUID())
        TurnRecorder.endTurn()
        XCTAssertEqual(sunk.first?.toolCalls.count ?? 0, 0)
    }

    // MARK: - Cloud AI Sharing (§10)

    func testTheProvidersAddressIsListedUnderWebSearchWhileItWouldSearch() {
        let model = ModelConfig(id: "a", name: "Claude", provider: LLMProvider.anthropic.rawValue,
                                apiKey: "k", model: "claude-sonnet-5-5", baseURL: "")
        let conversation = CloudServiceCatalog.route(for: model, accountConnected: false, vertexURL: nil)
        let spec = ProviderSearchSpec(provider: .anthropic, kind: .anthropic)
        let route = CloudServiceCatalog.providerSearchRoute(for: model, decision: .provider(spec),
                                                            conversationRoute: conversation)
        XCTAssertEqual(route?.scope, .webSearch)
        XCTAssertEqual(route?.url, conversation?.url)
        XCTAssertNil(CloudServiceCatalog.providerSearchRoute(for: model, decision: .ourTool(.switchOff),
                                                             conversationRoute: conversation))
        // One service, two uses: one question about the origin, not a second service.
        let services = CloudServiceCatalog.services(routes: [conversation!, route!])
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(Set(services[0].scopes), [.conversation, .webSearch])
    }

    // MARK: - The privacy copy (§10)

    func testThePrivacyPageAndManifestDescribeProviderSearch() throws {
        let page = try text("privacy.html")
        XCTAssertTrue(page.contains("Let the AI search the web itself"))
        XCTAssertTrue(page.contains("the query goes to that provider instead"))
        XCTAssertTrue(page.contains("Google keeps the prompt and the answer for 30 days"))
        XCTAssertTrue(page.contains("the pages and passages it cited"))
        let manifest = try text("OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy")
        XCTAssertTrue(manifest.contains("on the conversation route"))
        XCTAssertTrue(manifest.contains("30 days"))
        XCTAssertTrue(manifest.contains("NSPrivacyCollectedDataTypeSearchHistory"), "still declared: our tool stays")
        let diagnostics = try text("OpenGlasses/Sources/App/Views/DiagnosticsSupportView.swift")
        XCTAssertTrue(diagnostics.contains("web search queries, and the text or pages the search returned"))
    }

    func testNoNewNetworkRouteForProviderSearch() {
        // A provider search travels inside the conversation request (§10): the web-search route
        // stays only for our own tool, owned by it.
        let route = NetworkRoute.webSearch
        XCTAssertTrue(NetworkRoute.allCases.contains(route))
        XCTAssertFalse(NetworkRoute.allCases.map(\.rawValue).contains { $0.lowercased().contains("provider") && $0.lowercased().contains("search") })
    }
}
