import XCTest
@testable import OpenGlasses

/// Plan KT P2 — drafts by a model, in the wearer's voice. The route order and every gate on the
/// cloud (consent, Medical Compliance, the blocked list for caption text); what the outgoing
/// request holds, asserted on the request itself; the writer's fallbacks, one fake model draft per
/// validator row; one call per card from the feed builder; and the edit learner's thresholds.
/// Invented people and numbers only.
@MainActor
final class PreparedCardDraftWriterTests: XCTestCase {

    // MARK: - Fixtures

    private static let anthropicKey = ModelConfig(id: "cfg-anthropic", name: "Example Claude", provider: "anthropic",
                                                  apiKey: "test-key-0000", model: "claude-example",
                                                  baseURL: LLMProvider.anthropic.defaultBaseURL)
    private static let geminiKey = ModelConfig(id: "cfg-gemini", name: "Example Gemini", provider: "gemini",
                                               apiKey: "test-key-0001", model: "gemini-example",
                                               baseURL: LLMProvider.gemini.defaultBaseURL)
    private static let openAIKey = ModelConfig(id: "cfg-openai", name: "Example GPT", provider: "openai",
                                               apiKey: "test-key-0002", model: "gpt-example",
                                               baseURL: LLMProvider.openai.defaultBaseURL)
    private static let claudeSignIn = ModelConfig(id: "cfg-claude-account", name: "Claude account", provider: "anthropic",
                                                  apiKey: "", model: "claude-example",
                                                  baseURL: LLMProvider.anthropic.defaultBaseURL)
    private static let chatGPT = ModelConfig(id: "cfg-chatgpt", name: "ChatGPT", provider: "chatgpt",
                                             apiKey: "", model: "gpt-example", baseURL: LLMProvider.chatgpt.defaultBaseURL)

    private static func target(_ config: ModelConfig) -> DraftCloudTarget { DraftCloudTarget(config: config)! }

    private func inputs(apple: Bool = false, local: Bool = false, foreground: Bool = true,
                        choice: DraftWriterChoice = .cloud, cloud: ModelConfig? = anthropicKey,
                        consented: Bool = true, hipaa: Bool = false, localOnly: Bool = false,
                        caption: Bool = false) -> DraftRouteInputs {
        let target = cloud.flatMap(DraftCloudTarget.init(config:))
        return DraftRouteInputs(appleOnDeviceAvailable: apple, localModelLoaded: local, isForeground: foreground,
                                choice: choice, cloud: target, cloudConsent: consented ? target?.consentKey : nil,
                                hipaaMode: hipaa, medicalLocalOnly: localOnly, carriesCaptionText: caption)
    }

    private static let template = "On my way — there about 18:45."

    private func leaveByRequest(template: String = template) -> DraftWriteRequest {
        DraftWriteRequest(cardId: PreparedCardID(kind: .leaveBy, occurrence: "gig-1:2026-11-12"), kind: .leaveBy,
                          channel: .messages, language: "en-GB", template: template, recipientFirstName: "Ana",
                          facts: [CardFact(label: "Leave by", value: "18:15"), CardFact(label: "Arrive by", value: "18:45")],
                          trustedText: [template, "Leave by", "18:15", "Arrive by", "18:45", "Ana Example",
                                        "Gig at the Example Hall"],
                          actionItems: [], untrustedSource: nil)
    }

    private static let items = ["Ana will send the draft plan", "Lee to book the room for Friday"]
    /// Caption text with a long run that is not an action item.
    private static let transcript = "Ana will send the draft plan. Lee to book the room for Friday. "
        + "Honestly the old supplier kept missing every single delivery date we gave them all through the spring."
    private static var recapTemplate: String {
        "Hi all,\n\nThanks for today. Here's what we agreed:\n" + DraftTemplates.bulletList(items) + "\n\nSam Example"
    }

    private func recapRequest() -> DraftWriteRequest {
        DraftWriteRequest(cardId: PreparedCardID(kind: .meetingFollowUp, occurrence: "plan-1:2026-11-12"),
                          kind: .meetingFollowUp, channel: .email, language: "en-GB",
                          template: Self.recapTemplate, recipientFirstName: nil,
                          facts: Self.items.map { CardFact(label: "Agreed", value: $0) },
                          trustedText: [Self.recapTemplate, "Planning", "Sam Example", "Ana Example, Lee Example"] + Self.items,
                          actionItems: Self.items, untrustedSource: Self.transcript)
    }

    private func writer(_ engine: FakeDraftEngine) -> DraftWriter {
        DraftWriter(call: DraftModelCall(engine: engine, timeout: 5))
    }

    // MARK: - Route order (decision 5)

    func testAppleFirstThenTheLocalModelInFrontThenTheCloud() {
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(apple: true, local: true)).get(), .appleOnDevice)
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(local: true)).get(), .localModel)
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(local: true, foreground: false)).get(),
                       .cloud(Self.target(Self.anthropicKey)), "the local model only while the app is in front")
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs()).get(), .cloud(Self.target(Self.anthropicKey)))
    }

    func testOnThisPhoneOnlyNeverReachesTheCloud() {
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(choice: .onThisPhone)), .failure(.nothingOnDevice))
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(local: true, foreground: false, choice: .onThisPhone)),
                       .failure(.nothingOnDevice))
    }

    func testTheCloudNeedsItsConsentForThisModelAtThisAddress() {
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(consented: false)), .failure(.cloudNotConsented))
        var moved = inputs()
        var config = Self.anthropicKey
        config.baseURL = "https://proxy.example.com/v1/messages"
        moved.cloud = DraftCloudTarget(config: config)
        XCTAssertEqual(DraftRoutePolicy.decide(moved), .failure(.cloudNotConsented),
                       "the consent was for another host")
        var other = inputs()
        other.cloud = Self.target(Self.openAIKey)
        XCTAssertEqual(DraftRoutePolicy.decide(other), .failure(.cloudNotConsented), "…or another model")
    }

    func testNeverTheCloudUnderMedicalComplianceOrItsLocalOnly() {
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(hipaa: true)), .failure(.medicalCompliance))
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(hipaa: true, localOnly: true)), .failure(.medicalCompliance))
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(localOnly: true)), .failure(.medicalCompliance))
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(apple: true, hipaa: true, localOnly: true)).get(),
                       .appleOnDevice, "on the phone is still fine")
        XCTAssertFalse(DraftRoutePolicy.canOffer(Self.target(Self.anthropicKey), hipaaMode: true, medicalLocalOnly: false))
    }

    func testAMeetingFollowUpNeverReachesABlockedRoute() {
        for config in [Self.geminiKey, Self.claudeSignIn, Self.chatGPT] {
            XCTAssertEqual(DraftRoutePolicy.decide(inputs(cloud: config, caption: true)),
                           .failure(.blockedForCaptionText), config.name)
        }
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(cloud: Self.geminiKey)).get(),
                       .cloud(Self.target(Self.geminiKey)), "other drafts may still use the Gemini key")
        XCTAssertEqual(try DraftRoutePolicy.decide(inputs(cloud: Self.anthropicKey, caption: true)).get(),
                       .cloud(Self.target(Self.anthropicKey)), "an API key on a paid account is not blocked")
        XCTAssertTrue(Self.target(Self.geminiKey).isBlockedForCaptionText)
        XCTAssertFalse(Self.target(Self.openAIKey).isBlockedForCaptionText)
    }

    func testSignInRoutesWriteNoDrafts() {
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(cloud: Self.chatGPT)), .failure(.cloudUnsupported))
        XCTAssertEqual(DraftRoutePolicy.decide(inputs(cloud: Self.claudeSignIn)), .failure(.cloudUnsupported))
        XCTAssertNil(DraftCloudTarget(config: ModelConfig(id: "l", name: "Local", provider: "local", apiKey: "",
                                                          model: "m", baseURL: "")))
    }

    func testTheCallIsNeverMadeWhenNoRouteIsAllowed() async {
        let cases: [(DraftRouteInputs, DraftNoRouteReason)] = [
            (inputs(consented: false), .cloudNotConsented),
            (inputs(hipaa: true), .medicalCompliance),
            (inputs(localOnly: true), .medicalCompliance),
            (inputs(cloud: Self.geminiKey, caption: true), .blockedForCaptionText),
        ]
        for (routeInputs, reason) in cases {
            let engine = FakeDraftEngine(inputs: routeInputs)
            let result = await writer(engine).write(routeInputs.carriesCaptionText ? recapRequest() : leaveByRequest(),
                                                    style: .standard)
            XCTAssertEqual(result.fallback, .noRoute(reason))
            XCTAssertEqual(result.origin, .template)
            XCTAssertTrue(engine.requests.isEmpty, "nothing reached a model for \(reason)")
        }
    }

    // MARK: - What leaves (asserted on the request)

    func testTheRequestHoldsTheTemplateFactsAndStyleAndNothingElse() async throws {
        let engine = FakeDraftEngine(inputs: inputs(apple: true), reply: "Leaving now, there about 18:45.")
        var style = WritingStyle.standard
        style.signOff = "Cheers"
        _ = await writer(engine).write(leaveByRequest(), style: style)
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(request.route, .appleOnDevice)

        // Two strings and a cap: there is no field a tool list, a history or a memory could ride in.
        XCTAssertEqual(Mirror(reflecting: request).children.compactMap(\.label),
                       ["route", "instructions", "prompt", "maxOutputTokens"])
        XCTAssertTrue(request.prompt.contains(Self.template))
        XCTAssertTrue(request.prompt.contains("Arrive by: 18:45"))
        XCTAssertTrue(request.prompt.contains("To: Ana"))
        XCTAssertFalse(request.prompt.contains("Ana Example"), "a first name only")
        XCTAssertTrue(request.instructions.contains("End with this sign-off on its own line, exactly: Cheers"))
        XCTAssertTrue(request.instructions.contains("Use no emoji."))
    }

    func testNoAddressOrWearerContextReachesTheCall() async throws {
        // The route has no access to the conversation at all: the engine is handed the two strings
        // the prompt builder made from the card, and an address on the card never gets into them.
        let engine = FakeDraftEngine(inputs: inputs(apple: true), reply: "Leaving now, there about 18:45.")
        let card = PreparedCard(
            id: PreparedCardID(kind: .leaveBy, occurrence: "gig-1:2026-11-12"), headline: "Leave by 18:15",
            subject: "Gig at the Example Hall", signals: [CardSignal(source: .calendar, text: "19:00")],
            facts: [CardFact(label: "Leave by", value: "18:15"), CardFact(label: "Phone", value: "555-0142")],
            primary: .dismiss,
            draft: PreparedDraft(channel: .messages,
                                 recipient: DraftRecipient(name: "Ana Example", addresses: ["555-0142"],
                                                           source: .calendarAttendee),
                                 text: Self.template, language: "en-GB"),
            urgency: .upcoming, dueAt: nil, validUntil: CardFixtures.at(19))
        let request = try XCTUnwrap(DraftWriteRequest.make(card: card, template: Self.template,
                                                           wearerName: "Sam Example", meeting: nil))
        _ = await writer(engine).write(request, style: .standard)
        let sent = try XCTUnwrap(engine.requests.first)
        for text in [sent.prompt, sent.instructions] {
            XCTAssertFalse(text.contains("555-0142"), "the recipient's address never reaches the model")
            XCTAssertFalse(text.contains("Sam Example"), "nor the wearer's name, unless the template has it")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("tool"), "no tool is described or offered")
        }
        XCTAssertFalse(request.facts.contains { $0.value == "555-0142" })
        XCTAssertTrue(request.trustedText.contains("Sam Example"), "…though the validator may accept it")
    }

    func testAMeetingRecapSendsTheItemsAsUntrustedAndNeverTheCaptionText() async throws {
        let engine = FakeDraftEngine(inputs: inputs(apple: true, caption: true),
                                     reply: "Hi all,\n\nThanks for the time today. We agreed:\n[LIST]\n\nSam Example")
        let result = await writer(engine).write(recapRequest(), style: .standard)
        let sent = try XCTUnwrap(engine.requests.first)
        XCTAssertTrue(sent.prompt.contains("<untrusted_tool_output tool=\"meeting_summary\">"))
        XCTAssertTrue(sent.prompt.contains("[LIST]"))
        XCTAssertFalse(sent.prompt.contains("old supplier"), "the caption text stays on the phone")
        XCTAssertFalse(sent.prompt.contains("<message>\nHi all,\n\nThanks for today. Here's what we agreed:\n•"),
                       "the list is not in the message to rewrite")
        XCTAssertNil(result.fallback)
        XCTAssertTrue(result.text.contains(DraftTemplates.bulletList(Self.items)), "the app puts the rule's list in")
        XCTAssertFalse(result.text.contains("[LIST]"))
    }

    func testTheCloudTransportSendsOneMessageAndNoTools() throws {
        func body(_ config: ModelConfig) throws -> [String: Any] {
            let request = try DraftCloudTransport.urlRequest(for: config, instructions: "RULES", prompt: "PROMPT",
                                                             maxOutputTokens: 400)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        let anthropic = try body(Self.anthropicKey)
        XCTAssertEqual(Set(anthropic.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual((anthropic["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(anthropic["system"] as? String, "RULES")

        let openAI = try body(Self.openAIKey)
        XCTAssertNil(openAI["tools"])
        let messages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] as? String }, ["RULES", "PROMPT"])

        let gemini = try body(Self.geminiKey)
        XCTAssertEqual(Set(gemini.keys), ["systemInstruction", "contents", "generationConfig"])
        XCTAssertEqual((gemini["contents"] as? [[String: Any]])?.count, 1)

        XCTAssertThrowsError(try DraftCloudTransport.urlRequest(for: Self.chatGPT, instructions: "", prompt: "",
                                                                maxOutputTokens: 1))
        XCTAssertThrowsError(try DraftCloudTransport.urlRequest(for: Self.claudeSignIn, instructions: "", prompt: "",
                                                                maxOutputTokens: 1))
    }

    func testTheCloudTransportReadsEachProvidersReply() throws {
        let anthropic = #"{"content":[{"type":"text","text":"Hi"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try DraftCloudTransport.text(from: anthropic, provider: .anthropic), "Hi")
        let openAI = #"{"choices":[{"message":{"content":"Hi"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try DraftCloudTransport.text(from: openAI, provider: .openai), "Hi")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try DraftCloudTransport.text(from: gemini, provider: .gemini), "Hi")
        XCTAssertThrowsError(try DraftCloudTransport.text(from: Data("{}".utf8), provider: .openai))
    }

    // MARK: - The writer's results and fallbacks

    func testAPassingDraftIsUsedAndSaysWhereItWasWritten() async {
        let onPhone = await writer(FakeDraftEngine(inputs: inputs(apple: true), reply: "“Leaving now, there about 18:45.”"))
            .write(leaveByRequest(), style: .standard)
        XCTAssertNil(onPhone.fallback)
        XCTAssertEqual(onPhone.text, "Leaving now, there about 18:45.", "quotation marks round it go")
        XCTAssertEqual(onPhone.origin, .onDevice)

        let cloud = await writer(FakeDraftEngine(inputs: inputs(), reply: "Leaving now, there about 18:45."))
            .write(leaveByRequest(), style: .standard)
        XCTAssertEqual(cloud.origin, .cloud(provider: Self.anthropicKey.providerDisplayName))
    }

    func testAFailedOrSilentModelKeepsTheTemplate() async {
        let failing = FakeDraftEngine(inputs: inputs(apple: true))
        failing.error = DraftCallFailure.modelFailed
        let failed = await writer(failing).write(leaveByRequest(), style: .standard)
        XCTAssertEqual(failed, DraftWriteResult(text: Self.template, origin: .template, fallback: .modelFailed))

        let silent = await writer(FakeDraftEngine(inputs: inputs(apple: true), reply: "   "))
            .write(leaveByRequest(), style: .standard)
        XCTAssertEqual(silent.fallback, .modelFailed)
    }

    func testAModelThatNeverAnswersTimesOutToTheTemplate() async {
        let slow = FakeDraftEngine(inputs: inputs(apple: true), reply: "Leaving now, there about 18:45.")
        slow.delay = 2
        let result = await DraftWriter(call: DraftModelCall(engine: slow, timeout: 0.1))
            .write(leaveByRequest(), style: .standard)
        XCTAssertEqual(result.fallback, .modelFailed)
    }

    /// A fake model whose draft breaks each row of §4.4 in turn: every one falls back to the
    /// template, and says which row.
    func testAModelDraftBreakingEachValidatorRowFallsBackToTheTemplate() async {
        let rows: [(String, DraftValidationFailure)] = [
            ("\"\"", .empty),
            ("On my way, there about {arrival}.", .placeholderLeft),
            ("**On my way**, there about 18:45.", .markdown),
            (String(repeating: "On my way, there soon. ", count: 20), .tooLong),
            ("On my way, the map is at example.com/hall", .url),
            ("On my way. Reply to sam@example.com if plans change.", .emailAddress),
            ("On my way. Call me on 555-0100 if you need me.", .phoneNumber),
            ("On my way, parking is $12 so I'll be quick.", .moneyAmount),
            ("On my way, there about 19:30.", .timeOrDateNotInFacts),
            ("On my way, see you on Friday.", .timeOrDateNotInFacts),
            ("Je suis en route et j'arrive vers 18:45 pour le concert avec toi ce soir.", .wrongLanguage),
        ]
        for (reply, row) in rows {
            let result = await writer(FakeDraftEngine(inputs: inputs(apple: true), reply: reply))
                .write(leaveByRequest(), style: .standard)
            XCTAssertEqual(result, DraftWriteResult(text: Self.template, origin: .template, fallback: .invalid(row)),
                           "\(row): \(reply)")
        }
        XCTAssertEqual(Set(rows.map(\.1)), Set(DraftValidationFailure.allCases).subtracting([.copiedCaptionText]),
                       "every row but the meeting one, which has its own test")
    }

    func testARecapCopyingMoreThanTwelveCaptionWordsFallsBack() async {
        let copying = "Hi all,\n\nThe old supplier kept missing every single delivery date we gave them all through the spring. We agreed:\n[LIST]\n\nSam Example"
        let result = await writer(FakeDraftEngine(inputs: inputs(apple: true, caption: true), reply: copying))
            .write(recapRequest(), style: .standard)
        XCTAssertEqual(result, DraftWriteResult(text: Self.recapTemplate, origin: .template,
                                                fallback: .invalid(.copiedCaptionText)))

        let twelve = "Hi all,\n\nThe old supplier kept missing every single delivery date we gave them, sadly. We agreed:\n[LIST]\n\nSam Example"
        let fine = await writer(FakeDraftEngine(inputs: inputs(apple: true, caption: true), reply: twelve))
            .write(recapRequest(), style: .standard)
        XCTAssertNil(fine.fallback, "twelve words in a row is the limit, not over it")
    }

    func testARecapThatDropsOrRepeatsTheListFallsBack() async {
        for reply in ["Hi all,\n\nThanks for today.\n\nSam Example", "Hi all,\n[LIST]\n[LIST]\n\nSam Example"] {
            let result = await writer(FakeDraftEngine(inputs: inputs(apple: true, caption: true), reply: reply))
                .write(recapRequest(), style: .standard)
            XCTAssertEqual(result.fallback, .listMarkerMissing)
            XCTAssertEqual(result.text, Self.recapTemplate)
        }
    }

    func testARecapWhoseTemplateHasNoListIsNotSent() async {
        let engine = FakeDraftEngine(inputs: inputs(apple: true, caption: true), reply: "x")
        let request = recapRequest()
        let odd = DraftWriteRequest(cardId: request.cardId, kind: request.kind, channel: request.channel,
                                    language: request.language, template: "Hi all, thanks.",
                                    recipientFirstName: nil, facts: request.facts, trustedText: request.trustedText,
                                    actionItems: request.actionItems, untrustedSource: request.untrustedSource)
        let result = await writer(engine).write(odd, style: .standard)
        XCTAssertEqual(result.fallback, .templateNotRecognised)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    // MARK: - One call per card, from the feed builder

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCardDraft_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func builder(writer: (any DraftWriting)?, metrics: DraftRecordingMetrics = DraftRecordingMetrics())
        -> PreparedCardFeedBuilder {
        let context = DraftCardContext(context: PreparedCardContext(
            travelDistanceMeters: 5_000, contacts: ["ana@example.com": CardContact(name: "Ana Example", phone: "555-0142")],
            wearer: CardWearer(name: "Sam Example")))
        let builder = PreparedCardFeedBuilder(
            store: PreparedCardStore(directory: directory), metrics: metrics, contextSource: context,
            calendar: { CardFixtures.calendar }, locale: CardFixtures.locale, isEnabled: { true },
            settings: { _, _ in CardFixtures.settings })
        builder.draftWriter = writer
        contexts.append(context)
        return builder
    }

    /// The builder holds its context source weakly.
    private var contexts: [DraftCardContext] = []

    private func gigFeed(_ builder: PreparedCardFeedBuilder, now: Date = CardFixtures.at(17)) async -> PreparedCardFeed {
        let inputs = CardFixtures.gigInputs().myDay
        let snapshot = MyDayComposer(calendar: CardFixtures.calendar, locale: CardFixtures.locale)
            .compose(inputs: inputs, now: now)
        return await builder.build(inputs: inputs, snapshot: snapshot, now: now)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testACardIsDraftedOnceWhenFirstShownAndThenKept() async throws {
        let fake = ScriptedWriter(result: { request in
            DraftWriteResult(text: "Leaving now, see you soon.", origin: .onDevice, fallback: nil)
        })
        let metrics = DraftRecordingMetrics()
        let builder = builder(writer: fake, metrics: metrics)
        var changes = 0
        builder.onDraftsChanged = { changes += 1 }
        let first = await gigFeed(builder)
        let card = try XCTUnwrap(first.feed.cards.first)
        XCTAssertEqual(card.draft?.origin, .template, "built, not yet shown: nothing is called")
        XCTAssertTrue(fake.requests.isEmpty)

        builder.noteShown([card], now: CardFixtures.at(17))
        await settle()
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.template, card.draft?.text, "written from the rule's template")
        XCTAssertEqual(changes, 1)
        let drafted = try XCTUnwrap(builder.rejoin(now: CardFixtures.at(17, 1))?.feed.cards.first)
        XCTAssertEqual(drafted.draft?.text, "Leaving now, see you soon.")
        XCTAssertEqual(drafted.draft?.origin, .onDevice)
        XCTAssertTrue(metrics.events.contains(.draftOrigin(.onDevice)))

        // Shown again, rebuilt: never called again.
        builder.noteShown([drafted], now: CardFixtures.at(17, 2))
        let rebuiltFeed = await gigFeed(builder, now: CardFixtures.at(17, 3))
        let rebuilt = try XCTUnwrap(rebuiltFeed.feed.cards.first)
        builder.noteShown([rebuilt], now: CardFixtures.at(17, 3))
        await settle()
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(rebuilt.draft?.text, "Leaving now, see you soon.")
        XCTAssertTrue(rebuiltFeed.changedDrafts.isEmpty, "the model's draft is not a change of times")
    }

    func testAFallbackStaysASimpleDraftAndIsNotAskedAgain() async throws {
        let fake = ScriptedWriter(result: { request in .template(request, .invalid(.phoneNumber)) })
        let metrics = DraftRecordingMetrics()
        let builder = builder(writer: fake, metrics: metrics)
        let feed = await gigFeed(builder)
        let card = try XCTUnwrap(feed.feed.cards.first)
        builder.noteShown([card], now: CardFixtures.at(17))
        await settle()
        builder.noteShown([card], now: CardFixtures.at(17, 1))
        await settle()
        XCTAssertEqual(fake.requests.count, 1)
        let after = try XCTUnwrap(builder.rejoin(now: CardFixtures.at(17, 1))?.feed.cards.first)
        XCTAssertEqual(after.draft?.origin, .template)
        XCTAssertEqual(PreparedCardPresentation.draftModel(try XCTUnwrap(after.draft)).footer, "Simple draft")
        XCTAssertTrue(metrics.events.contains(.validatorFallback(.phoneNumber)))
        XCTAssertTrue(metrics.events.contains(.draftOrigin(.template)))
    }

    func testNoRouteYetMayBeAskedAgainLater() async throws {
        let fake = ScriptedWriter(result: { request in .template(request, .noRoute(.nothingOnDevice)) })
        let builder = builder(writer: fake)
        let feed = await gigFeed(builder)
        let card = try XCTUnwrap(feed.feed.cards.first)
        builder.noteShown([card], now: CardFixtures.at(17))
        await settle()
        builder.noteShown([card], now: CardFixtures.at(17, 1))
        await settle()
        XCTAssertEqual(fake.requests.count, 2, "nothing was called, so a model ready later may write it")
    }

    func testAnEditedCardIsNotSentToAModel() async throws {
        let fake = ScriptedWriter(result: { _ in DraftWriteResult(text: "x", origin: .onDevice, fallback: nil) })
        let builder = builder(writer: fake)
        let feed = await gigFeed(builder)
        let card = try XCTUnwrap(feed.feed.cards.first)
        builder.edit(card, text: "Leaving now, Ana", now: CardFixtures.at(17))
        builder.noteShown([card], now: CardFixtures.at(17))
        await settle()
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testAnEditHandedOffTeachesTheLearnerCountsOnly() async throws {
        let builder = builder(writer: nil)
        let style = WritingStyleStore(directory: directory)
        builder.styleStore = style
        let feed = await gigFeed(builder)
        let card = try XCTUnwrap(feed.feed.cards.first)
        let base = try XCTUnwrap(card.draft?.text)
        builder.edit(card, text: "Hi Ana,\n\n" + base, now: CardFixtures.at(17))
        builder.handedOff(card, result: .cancelled, now: CardFixtures.at(17, 1))
        XCTAssertEqual(style.counts.edits, 0, "a cancelled composer teaches nothing")
        builder.handedOff(card, result: .sent, now: CardFixtures.at(17, 2))
        builder.handedOff(card, result: .sent, now: CardFixtures.at(17, 3))
        XCTAssertEqual(style.counts.edits, 1, "once per card")
        XCTAssertEqual(style.counts.count(.addedGreeting), 1)

        let file = try String(contentsOf: directory.appendingPathComponent("style.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("Ana"), "no message text is kept")
        XCTAssertFalse(file.contains("18:"), "no message text is kept")
    }

    // MARK: - The edit learner (§4.3)

    func testThreeConsistentEditsProposeAChangeAndTwoDoNot() {
        let before = "Hi Ana,\n\nOn my way, there about 18:45.\n\nCheers, Sam"
        let after = "On my way, there about 18:45.\n\nCheers, Sam"
        var style = WritingStyle.standard
        style.greeting = .hiName
        var counts = StyleEditCounts()
        for _ in 0..<2 {
            counts = StyleEditLearner.record(StyleEditLearner.signals(before: before, after: after), into: counts)
        }
        XCTAssertNil(StyleEditLearner.suggestion(counts: counts, style: style), "two is not yet a habit")
        counts = StyleEditLearner.record(StyleEditLearner.signals(before: before, after: after), into: counts)
        let suggestion = StyleEditLearner.suggestion(counts: counts, style: style)
        XCTAssertEqual(suggestion?.signal, .cutGreeting)
        XCTAssertEqual(suggestion?.question, "You often cut the greeting. Stop adding one?")
        XCTAssertEqual(StyleEditLearner.apply(suggestion!, to: style).greeting, .none)
    }

    func testAnEditTheOtherWayStartsTheCountAgain() {
        let withGreeting = "Hi Ana,\n\nOn my way."
        let without = "On my way."
        var counts = StyleEditCounts()
        counts = StyleEditLearner.record(StyleEditLearner.signals(before: withGreeting, after: without), into: counts)
        counts = StyleEditLearner.record(StyleEditLearner.signals(before: withGreeting, after: without), into: counts)
        counts = StyleEditLearner.record(StyleEditLearner.signals(before: without, after: withGreeting), into: counts)
        XCTAssertEqual(counts.count(.cutGreeting), 0)
        XCTAssertEqual(counts.count(.addedGreeting), 1)
        counts = StyleEditLearner.record(StyleEditLearner.signals(before: withGreeting, after: without), into: counts)
        XCTAssertNil(StyleEditLearner.suggestion(counts: counts, style: .standard))
    }

    func testNothingIsProposedThatTheStyleAlreadySays() {
        var counts = StyleEditCounts()
        counts.counts[.cutGreeting] = 5
        var style = WritingStyle.standard
        style.greeting = .none
        XCTAssertNil(StyleEditLearner.suggestion(counts: counts, style: style))
        counts.counts[.cutSignOff] = 3
        XCTAssertNil(StyleEditLearner.suggestion(counts: counts, style: style), "no sign-off in the note to stop")
        style.signOff = "Cheers"
        XCTAssertEqual(StyleEditLearner.suggestion(counts: counts, style: style)?.signal, .cutSignOff)
    }

    func testTheSignalsAnEditGives() {
        XCTAssertEqual(StyleEditLearner.signals(before: "On my way, there about 18:45 tonight for the gig.",
                                                after: "On my way."), [.shortened])
        XCTAssertEqual(StyleEditLearner.signals(before: "On my way 🙂", after: "On my way"), [.removedEmoji])
        XCTAssertEqual(StyleEditLearner.signals(before: "On my way.\n\nCheers, Sam", after: "On my way."),
                       [.cutSignOff])
        XCTAssertEqual(StyleEditLearner.signals(before: "On my way.\n\nCheers, Sam", after: "On my way.\n\nThanks, Sam"),
                       [.changedSignOff])
        XCTAssertEqual(StyleEditLearner.signals(before: "On my way.", after: "On my way!"), [])
    }

    func testAcceptingOrIgnoringSettlesTheSuggestion() throws {
        let store = WritingStyleStore(directory: directory)
        for _ in 0..<3 { store.learn(before: "On my way 🙂", after: "On my way") }
        store.update { $0.emoji = true }
        let suggestion = try XCTUnwrap(store.suggestion)
        XCTAssertEqual(suggestion.signal, .removedEmoji)
        store.ignore(suggestion)
        XCTAssertNil(store.suggestion)
        XCTAssertTrue(store.style.emoji, "ignoring changes nothing")

        for _ in 0..<3 { store.learn(before: "On my way 🙂", after: "On my way") }
        store.accept(try XCTUnwrap(store.suggestion))
        XCTAssertFalse(store.style.emoji)
        XCTAssertNil(store.suggestion)
        XCTAssertEqual(WritingStyleStore(directory: directory).style, store.style, "kept across a relaunch")
    }

    func testTheStyleNoteForgetsAPersonAndDeletesWhole() {
        let store = WritingStyleStore(directory: directory)
        store.update {
            $0.signOff = "Cheers, Sam Example"
            $0.freeLine = "Keep it brief"
        }
        XCTAssertEqual(store.forget(matching: "sam example"), 1)
        XCTAssertEqual(store.style.signOff, "")
        XCTAssertEqual(store.style.freeLine, "Keep it brief")
        store.deleteAll()
        XCTAssertEqual(store.style, .standard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("style.json").path))
    }

    func testTheStyleNoteGoesIntoTheInstructionsAsTheWearersOwn() {
        var style = WritingStyle.standard
        XCTAssertEqual(style.promptLines, ["Use no emoji."])
        style.greeting = .none
        style.length = .short
        style.formality = .formal
        style.emoji = true
        style.freeLine = "I never use exclamation marks"
        XCTAssertEqual(style.promptLines, [
            "Do not open with a greeting.", "Keep it as short as it can be.", "Write formally and politely.",
            "One emoji is fine if it suits.", "The writer's own note about their style: I never use exclamation marks",
        ])
        style.freeLine = String(repeating: "a", count: 500)
        XCTAssertEqual(style.freeLine.count, WritingStyle.freeLineLimit)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeDraftEngine: DraftModelEngine {
    var inputs: DraftRouteInputs
    var reply: String
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var requests: [DraftModelRequest] = []

    init(inputs: DraftRouteInputs, reply: String = "") {
        self.inputs = inputs
        self.reply = reply
    }

    func routeInputs(carriesCaptionText: Bool) -> DraftRouteInputs {
        var copy = inputs
        copy.carriesCaptionText = carriesCaptionText
        return copy
    }

    func run(_ request: DraftModelRequest) async throws -> String {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return reply
    }
}

@MainActor
private final class ScriptedWriter: DraftWriting {
    private let result: (DraftWriteRequest) -> DraftWriteResult
    private(set) var requests: [DraftWriteRequest] = []

    init(result: @escaping (DraftWriteRequest) -> DraftWriteResult) { self.result = result }

    func write(_ request: DraftWriteRequest, style: WritingStyle) async -> DraftWriteResult {
        requests.append(request)
        return result(request)
    }
}

@MainActor
private final class DraftCardContext: PreparedCardContextSource {
    var context: PreparedCardContext
    var isFieldAssistDay = false
    var healthAvailable = false

    init(context: PreparedCardContext) { self.context = context }

    func context(for inputs: MyDayInputs, settings: PreparedCardSettings, now: Date) async -> PreparedCardContext {
        context
    }

    func jobFacts(now: Date) -> CardJobFacts? { nil }
}

private final class DraftRecordingMetrics: PreparedCardMetricsRecording {
    var events: [PreparedCardMetricEvent] = []
    func record(_ event: PreparedCardMetricEvent) { events.append(event) }
}
