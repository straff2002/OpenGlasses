import XCTest
@testable import OpenGlasses

/// The building service with a scripted model, fake documentation and a fake service: drafts are
/// repaired, nothing reaches the new service before a yes, the yes names exactly the minimised
/// domains, and anything not approved is deleted with its test.
@MainActor
final class AddOnAuthoringServiceTests: XCTestCase {

    private var root: URL!
    private var clock: FakeAddOnClock!
    private var store: AddOnStore!
    private var drafts: AddOnDraftStore!
    private var install: AddOnInstallService!
    private var model: ScriptedAuthoringModel!
    private var docs: FakeDocsFetcher!
    private var transport: FakeAddOnHTTPTransport!
    private var consents: [AddOnTestConsentRequest] = []
    private var requestsAtConsent: [Int] = []
    private var consentAnswer = true
    private var announced: [String] = []
    private var searches: [String] = []
    private var conditions = AddOnAuthoringAvailability.Conditions(agentModeEnabled: true)
    private var native: [AddOnAuthoringPreflight.Capability] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddOnAuthoringServiceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = FakeAddOnClock()
        store = AddOnStore(directory: root.appendingPathComponent("addons"), backupDirectory: root)
        drafts = AddOnDraftStore(directory: root.appendingPathComponent("drafts"), backupDirectory: root)
        install = AddOnInstallService(store: store, context: { .init() }, fetch: { _ in Data() },
                                      networkDecision: .allowHardenedFetch)
        model = ScriptedAuthoringModel()
        docs = FakeDocsFetcher()
        transport = FakeAddOnHTTPTransport(clock: clock, json: #"{"next":{"time":"14:05"}}"#)
        consents = []
        requestsAtConsent = []
        consentAnswer = true
        announced = []
        searches = []
        conditions = .init(agentModeEnabled: true)
        native = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeService() -> AddOnAuthoringService {
        let deps = AddOnAuthoringService.Dependencies(
            model: model,
            search: { [unowned self] query in
                self.searches.append(query)
                return "Tides API — https://docs.example.org/tides — free, no key."
            },
            docs: docs,
            transport: transport,
            clock: clock,
            consent: { [unowned self] request in
                self.consents.append(request)
                self.requestsAtConsent.append(self.transport.requests.count)
                return self.consentAnswer
            },
            announce: { [unowned self] line in self.announced.append(line) },
            conditions: { [unowned self] in self.conditions },
            nativeCapabilities: { [unowned self] in self.native },
            runContext: { _ in
                RecipeRunContext(now: Date(timeIntervalSince1970: 1_794_000_000), timeZone: TimeZone(identifier: "UTC")!,
                                 locale: Locale(identifier: "en_NZ"), units: .metric, location: nil)
            })
        return AddOnAuthoringService(store: store, drafts: drafts, install: install, dependencies: deps)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - Fixtures

    private static func addOn(url: String = "https://tides.example.net/v1/next?place={{place}}",
                              extraNetwork: [String] = ["evil.example.com"], name: String = "Tide Times",
                              extraSteps: [[String: Any]] = []) -> [String: Any] {
        [
            "name": name,
            "description": "Says the next high tide at a place on the coast.",
            "icon": "water.waves",
            "permissions": ["network": ["tides.example.net"] + extraNetwork, "memory": true],
            "skills": [[
                "name": "next_tide",
                "description": "Use when the wearer asks when the next high tide is at a place.",
                "parameters": ["place": ["type": "string", "required": true, "maxLength": 60]],
                "steps": [
                    ["http": ["method": "GET", "url": url, "as": "r"]],
                    ["extract": ["from": "r", "jsonpath": "$.next.time", "as": "time"]],
                ] + extraSteps + [
                    ["if": ["op": "empty", "var": "time",
                            "then": [["say": "I couldn't find the tide."]],
                            "else": [["say": "High tide is at {{time}}."]]]],
                ],
            ]],
        ]
    }

    private static func draft(_ body: [String: Any]? = nil, docs: String = "https://docs.example.org/tides") -> String {
        let object: [String: Any] = [
            "action": "draft", "docs": docs,
            "sample": ["skill": "next_tide", "question": "When's high tide at Plimmerton?",
                       "arguments": ["place": "Plimmerton"]],
            "addon": body ?? addOn(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "Here it is:\n" + String(decoding: data, as: UTF8.self)
    }

    private static let search = #"{"action":"search","query":"free tide times API"}"#
    private static let fetch = #"{"action":"fetch","url":"https://docs.example.org/tides"}"#

    // MARK: - The whole flow

    func testAnInvalidDraftIsRepairedThenTestedAndInstalledOnlyOnApproval() async throws {
        model.replies = [Self.search, Self.fetch,
                         Self.draft(Self.addOn(url: "https://{{place}}.example.net/next")),
                         Self.draft()]
        let service = makeService()
        guard case .started = service.start(goal: "tide times at the coast") else { return XCTFail() }
        await service.waitForSession()

        XCTAssertEqual(model.calls.count, 4)
        XCTAssertEqual(searches, ["free tide times API"])
        XCTAssertEqual(docs.fetched.map(\.absoluteString), ["https://docs.example.org/tides"])
        XCTAssertTrue(model.calls[3].user.contains("scheme and host must be written out"),
                      "the repair prompt names what was wrong")
        XCTAssertTrue(model.calls[2].user.contains(PromptInjectionPolicy.wrap(toolName: "addon_docs", content: FakeDocsFetcher.text)),
                      "fetched pages reach the model only as framed data")

        // One consent, before the only request, naming the minimised set (the extra host is gone).
        XCTAssertEqual(consents.map(\.domains), [["tides.example.net"]])
        XCTAssertEqual(requestsAtConsent, [0])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(consents.first?.line, "To test it, I'll contact tides.example.net once with a sample question. OK?")

        // Waiting on the phone sheet, with its test; nothing installed.
        guard case .review(let review) = install.prompt else { return XCTFail("\(String(describing: install.prompt))") }
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertEqual(service.session?.phase, .awaitingApproval)
        XCTAssertEqual(drafts.drafts.count, 1)
        let manifest = review.candidate.manifest
        XCTAssertEqual(manifest.id, "local.assistant.tide-times")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.author.name, SelfBuiltIdentity.authorName)
        XCTAssertEqual(manifest.author.web, "https://docs.example.org/tides")
        XCTAssertEqual(manifest.permissions.network, ["tides.example.net"])
        XCTAssertFalse(manifest.permissions.memory, "declared but unused: stripped")
        let model = AddOnSheetModel(review: review)
        XCTAssertEqual(model.badges, [.builtByAssistant])
        XCTAssertFalse(model.badges.contains(.reviewed))
        XCTAssertEqual(model.tested?.question, "When's high tide at Plimmerton?")
        XCTAssertEqual(model.tested?.answer, "High tide is at 14:05.")
        XCTAssertEqual(model.tested?.domains, "tides.example.net")
        await settle()
        XCTAssertTrue(announced.contains("It works. Check your phone to approve it."))

        install.accept(review)
        let row = try XCTUnwrap(store.record(id: "local.assistant.tide-times"))
        XCTAssertTrue(row.isBuiltByAssistant)
        XCTAssertEqual(row.selfBuiltProvenance?.goal, "tide times at the coast")
        XCTAssertTrue(drafts.drafts.isEmpty, "an approved draft lives on only as the add-on")
        XCTAssertEqual(service.session?.phase, .installed)
    }

    func testNothingReachesTheServiceBeforeAYes() async {
        model.replies = [Self.draft()]
        consentAnswer = false
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()

        XCTAssertEqual(consents.count, 1)
        XCTAssertEqual(requestsAtConsent, [0])
        XCTAssertTrue(transport.requests.isEmpty, "a no means the service is never contacted")
        XCTAssertEqual(service.session?.phase, .discarded)
        XCTAssertEqual(service.session?.ending, .consentDeclined)
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertNil(install.prompt)
        await settle()
        XCTAssertTrue(announced.contains("OK, I won't test it. The draft is deleted."))
    }

    func testConsentNamesExactlyTheMinimisedDomains() async {
        let twoHosts = Self.addOn(extraNetwork: ["unused.example.org"], extraSteps: [
            ["http": ["method": "GET", "url": "https://backup.example.org/next?place={{place}}", "as": "b"]],
        ])
        model.replies = [Self.draft(twoHosts)]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(consents.map(\.domains), [["backup.example.org", "tides.example.net"]])
        guard case .review(let review) = install.prompt else { return XCTFail() }
        XCTAssertEqual(Set(consents[0].domains), Set(review.candidate.manifest.permissions.network))
        XCTAssertEqual(Set(transport.requests.compactMap { $0.url.host }).isSubset(of: Set(consents[0].domains)), true)
    }

    func testTurningItDownDeletesTheDraftAndItsTrace() async {
        model.replies = [Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(drafts.drafts.count, 1)
        XCTAssertEqual(drafts.drafts.first?.trace.hostsContacted, ["tides.example.net"])

        install.dismiss()
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertEqual(service.session?.ending, .rejected)
        // And it stays deleted across a relaunch.
        XCTAssertTrue(AddOnDraftStore(directory: root.appendingPathComponent("drafts"), backupDirectory: root).drafts.isEmpty)
    }

    func testAFailedTestIsRepairedAndAsksAgainBeforeTheNextTest() async {
        let calls = CallCounter()
        transport = FakeAddOnHTTPTransport(clock: clock) { _ in
            calls.next() == 0 ? .json(#"{"unexpected":true}"#) : .json(#"{"next":{"time":"06:40"}}"#)
        }
        model.replies = [Self.draft(), Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()

        XCTAssertEqual(consents.count, 2, "every test needs its own yes")
        XCTAssertEqual(requestsAtConsent, [0, 1])
        XCTAssertTrue(model.calls[1].user.contains("the extract found nothing"))
        XCTAssertEqual(service.session?.phase, .awaitingApproval)
        XCTAssertEqual(drafts.drafts.first?.trace.spoken, "High tide is at 06:40.")
    }

    func testAServiceThatNeverAnswersIsGivenUpAfterTheRepairs() async {
        transport = FakeAddOnHTTPTransport(clock: clock, json: "{}", status: 503)
        model.replies = [Self.draft(), Self.draft(), Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(consents.count, 3)
        XCTAssertEqual(service.session?.ending, .notReliable)
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertNil(install.prompt)
        await settle()
        XCTAssertTrue(announced.contains("I couldn't get that service to answer reliably, so I've deleted the draft."))
    }

    // MARK: - Ending early

    func testAKeyedServiceEndsWithTheFixedSentence() async {
        model.replies = [Self.search, #"{"action":"needs_key"}"#]
        let service = makeService()
        _ = service.start(goal: "flight prices to Sydney")
        await service.waitForSession()
        XCTAssertEqual(service.session?.ending, .needsKey)
        XCTAssertTrue(consents.isEmpty)
        await settle()
        XCTAssertTrue(announced.contains("That service needs an account key; I can't build that yet."))
    }

    func testACoveredGoalNeverStarts() {
        native = [.init(name: "convert_currency",
                        summary: "Convert an amount between currencies using live exchange rates. No API key needed.")]
        let service = makeService()
        guard case .refused(let message) = service.start(goal: "convert fifty euros to dollars") else { return XCTFail() }
        XCTAssertTrue(message.hasPrefix("I can already do that"))
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertTrue(drafts.sessionStarts().isEmpty, "a refused goal doesn't use one of the day's sessions")
    }

    func testPrivateDataIsRefusedAtTheStart() {
        let service = makeService()
        guard case .refused(let message) = service.start(goal: "read my text messages") else { return XCTFail() }
        XCTAssertTrue(message.contains("can never reach"))
        XCTAssertTrue(model.calls.isEmpty)
    }

    func testTheGatesRefuseBeforeAnything() {
        conditions = .init(agentModeEnabled: false)
        XCTAssertEqual(makeService().start(goal: "tides"), .refused(AddOnAuthoringAvailability.message(.agentModeOff)))
        conditions = .init(agentModeEnabled: true, hipaaMode: true)
        XCTAssertEqual(makeService().start(goal: "tides"), .refused(AddOnAuthoringAvailability.message(.medicalCompliance)))
        conditions = .init(agentModeEnabled: true, policy: AddOnPolicy(ceiling: .signedOnly))
        guard case .refused = makeService().start(goal: "tides") else { return XCTFail() }
        conditions = .init(agentModeEnabled: true, organisationForbidsSelfBuilt: true)
        XCTAssertEqual(makeService().start(goal: "tides"), .refused(AddOnAuthoringAvailability.message(.organisationForbids)))
        XCTAssertTrue(model.calls.isEmpty)
    }

    func testThreeSessionsADay() async {
        let service = makeService()
        for _ in 0..<3 {
            model.replies = [#"{"action":"give_up","reason":"none"}"#]
            guard case .started = service.start(goal: "tide times at the coast") else { return XCTFail() }
            await service.waitForSession()
        }
        XCTAssertEqual(service.start(goal: "tide times at the coast"),
                       .refused(AddOnAuthoringAvailability.message(.dailyLimit)))
        clock.advance(by: 24 * 60 * 60)
        model.replies = [#"{"action":"give_up","reason":"none"}"#]
        guard case .started = service.start(goal: "tide times at the coast") else { return XCTFail("a new day") }
        await service.waitForSession()
    }

    func testTenModelCallsAtMost() async {
        model.replies = Array(repeating: Self.search, count: 20)
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(model.calls.count, AddOnAuthoringSession.maxModelCalls)
        XCTAssertEqual(service.session?.ending, .limitReached(.modelCall))
    }

    func testThreeDocumentationPagesAtMost() async {
        model.replies = Array(repeating: Self.fetch, count: 4) + [Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(docs.fetched.count, AddOnAuthoringSession.maxDocsFetches)
        XCTAssertTrue(model.calls[4].user.contains("no more pages can be fetched"))
        XCTAssertEqual(service.session?.phase, .awaitingApproval)
    }

    func testCancelKeepsNothing() async {
        model.replies = [Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        XCTAssertEqual(drafts.drafts.count, 1)
        XCTAssertEqual(service.cancel(), "Stopped building the add-on. Nothing was kept.")
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertNil(install.prompt, "the sheet goes with it")
        XCTAssertEqual(service.session?.ending, .cancelled)
    }

    func testOneSessionAtATime() async {
        model.replies = [Self.draft()]
        model.holdFirstReply = true
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await settle()
        guard case .refused(let message) = service.start(goal: "ferry times") else { return XCTFail() }
        XCTAssertTrue(message.contains("already building"))
        model.release()
        await service.waitForSession()
    }

    // MARK: - Drafts

    func testAnUnapprovedDraftExpiresAfterADay() async {
        model.replies = [Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        install.prompt = nil   // the sheet was closed some other way; the draft waits in Settings
        XCTAssertEqual(drafts.drafts.count, 1)
        service.review(draftID: drafts.drafts[0].id)
        guard case .review(let again) = install.prompt else { return XCTFail("Settings can show it again") }
        XCTAssertNotNil(again.tested)
        install.prompt = nil

        clock.advance(by: AddOnAuthoringSession.draftLifetime)
        XCTAssertEqual(drafts.sweepExpired(now: clock.now()), 1)
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertTrue(service.status().contains("not building"))
    }

    // MARK: - Improving

    func testImprovingABuiltAddOnIsAVersionUpWithTheDiffSheet() async throws {
        model.replies = [Self.draft()]
        let service = makeService()
        _ = service.start(goal: "tide times at the coast")
        await service.waitForSession()
        guard case .review(let first) = install.prompt else { return XCTFail() }
        install.accept(first)

        let withCard = Self.addOn(extraSteps: [["display": ["kind": "text", "title": "Next tide", "items": ["{{time}}"]]]])
        model.replies = [Self.draft(withCard)]
        guard case .started = service.improve(addOnNamed: "tide times", goal: "show it on a card too") else { return XCTFail() }
        await service.waitForSession()
        XCTAssertTrue(model.calls.last?.user.contains("Improve this installed add-on") == true)
        guard case .review(let update) = install.prompt, case .update(let diff?) = update.kind else {
            return XCTFail("\(String(describing: install.prompt))")
        }
        XCTAssertEqual(update.candidate.manifest.id, "local.assistant.tide-times")
        XCTAssertEqual(update.candidate.manifest.version, "1.1.0")
        XCTAssertEqual(diff.permissionsAdded, [.display])
        XCTAssertEqual(consents.count, 2, "the new version is tested with its own yes")
        install.accept(update)
        XCTAssertEqual(store.record(id: "local.assistant.tide-times")?.version, "1.1.0")
    }

    func testOnlyAddOnsTheAssistantBuiltCanBeImproved() {
        let service = makeService()
        guard case .refused(let message) = service.improve(addOnNamed: "Currency", goal: "faster") else { return XCTFail() }
        XCTAssertTrue(message.contains("only improve add-ons I built"))
    }
}

// MARK: - Fakes

@MainActor
final class ScriptedAuthoringModel: AddOnAuthoringModel {
    struct Call { let system: String; let user: String }
    var replies: [String] = []
    private(set) var calls: [Call] = []
    var holdFirstReply = false
    private var held: CheckedContinuation<Void, Never>?

    func complete(system: String, user: String) async throws -> String {
        calls.append(Call(system: system, user: user))
        if holdFirstReply {
            holdFirstReply = false
            await withCheckedContinuation { held = $0 }
        }
        guard !replies.isEmpty else { return #"{"action":"give_up","reason":"no script"}"# }
        return replies.removeFirst()
    }

    func release() {
        held?.resume()
        held = nil
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// The number of calls before this one.
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

final class FakeDocsFetcher: AddOnDocsFetcher, @unchecked Sendable {
    static let text = "Tides API. GET https://tides.example.net/v1/next?place=NAME returns {\"next\":{\"time\":\"HH:MM\"}}. No key."
    private let lock = NSLock()
    private var urls: [URL] = []
    var fetched: [URL] { lock.withLock { urls } }

    func fetch(_ url: URL) async throws -> AddOnDocsPage {
        lock.withLock { urls.append(url) }
        return AddOnDocsPage(url: url, text: Self.text)
    }
}

/// The sheet's words for a self-built add-on, here and on another phone, and documentation text.
@MainActor
final class AddOnSelfBuiltSheetTests: XCTestCase {

    private func review(id: String, author: String, origin: AddOnOrigin,
                        tested: AddOnTestedSummary? = nil) throws -> AddOnInstallService.Review {
        let data = RecipeAddOnFixtures.file(skills: [[
            "name": "next_tide", "description": "Use when the wearer asks for the tide.",
            "steps": [["http": ["method": "GET", "url": "https://tides.example.net/v1", "as": "r"]], ["say": "{{r}}"]],
        ]], permissions: ["network": ["tides.example.net"]],
            overrides: ["id": id, "author": ["name": author, "web": "https://docs.example.org/tides"]])
        let manifest = try RecipeAddOnManifest.decode(data)
        return .init(id: UUID(), candidate: .init(manifest: manifest, fileBytes: data, envelopeBytes: nil,
                                                  trust: .community, signatureFailure: nil),
                     kind: .install, origin: origin, tested: tested)
    }

    func testBuiltHereSaysSoAndShowsItsTest() throws {
        let tested = AddOnTestedSummary(sessionID: "s", goal: "tides", sampleQuestion: "High tide at Raglan?",
                                        spokenAnswer: "High tide is at 14:05.", domainsContacted: ["tides.example.net"],
                                        elapsed: 1.24, testedAt: Date(), sourceText: "{}")
        let provenance = SelfBuiltAddOnProvenance(sessionID: "s", goal: "tides", builtAt: Date())
        let model = AddOnSheetModel(review: try review(id: "local.assistant.tides", author: SelfBuiltIdentity.authorName,
                                                       origin: .selfBuilt(provenance), tested: tested))
        XCTAssertEqual(model.byline, "Built by your assistant · data from docs.example.org")
        XCTAssertEqual(model.badges, [.builtByAssistant])
        XCTAssertEqual(model.tested?.domains, "tides.example.net")
        XCTAssertEqual(model.tested?.time, "1.2 seconds")
        XCTAssertNotNil(model.cancelNote)
        XCTAssertTrue(model.tested?.accessibilityText.contains("High tide at Raglan?") == true)
    }

    func testReceivedFromAnotherPhoneKeepsTheNoteButNotTheClaim() throws {
        let model = AddOnSheetModel(review: try review(id: "local.assistant.tides", author: SelfBuiltIdentity.authorName,
                                                       origin: .installed(via: .file)))
        XCTAssertEqual(model.badges, [.builtByAnotherAssistant])
        XCTAssertEqual(model.byline, "Built by an assistant on another phone · data from docs.example.org")
        XCTAssertNil(model.tested)
        XCTAssertNil(model.cancelNote)
        XCTAssertFalse(model.badges.contains(.reviewed))

        let ordinary = AddOnSheetModel(review: try review(id: "org.example.tides", author: "Jo Example",
                                                          origin: .installed(via: .file)))
        XCTAssertEqual(ordinary.badges, [])
        XCTAssertEqual(ordinary.byline, "By Jo Example · docs.example.org")
    }

    func testDocumentationHTMLIsReducedToItsWords() {
        let html = """
        <html><head><title>T</title><script>var x = "<b>";
        alert(1)</script></head><body><h1>Tides API</h1><p>GET <code>/v1/next?place=NAME</code> &amp; more</p>
        <!-- hidden
        comment --><style>p{}</style></body></html>
        """
        let text = AddOnDocsText.plainText(fromHTML: html)
        XCTAssertTrue(text.contains("Tides API"))
        XCTAssertTrue(text.contains("/v1/next?place=NAME"))
        XCTAssertTrue(text.contains("& more"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("hidden"))
        XCTAssertFalse(text.contains("<"))
    }
}
