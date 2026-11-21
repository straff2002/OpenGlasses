import XCTest
@testable import OpenGlasses

// Plan MO P2b (§5a): hints from the job's manuals. The scope, the provider rule, the citation,
// the sheet's summary, the search adapter over a faked job, the session over a faked search, the
// lens over a procedure's step card, and the procedure's voice keeping its priority. Every
// identifier and line here is invented.

@MainActor
final class FakeJobManualSource: HintJobManualSource {
    var hintJobManuals: HintJobManuals?
    var outcome: ManualHintSearch = .nothing(.insufficient)
    var titles: [String] = []
    private(set) var questions: [String] = []

    func hintPassages(for question: String, limit: Int) -> ManualHintSearch {
        questions.append(question)
        return outcome
    }

    func hintManualTitles() -> [String] { titles }
}

/// A search that returns what it is told, through the scope-aware entry point.
@MainActor
final class FakeScopedHintDocuments: HintDocumentSearch {
    var result = HintSearchResult(passages: [])
    private(set) var searches: [String] = []

    func passages(for question: String, limit: Int) -> [HintPassage] { result.passages }
    func documentTitles() -> [String] { [] }
    func search(for question: String, limit: Int) -> HintSearchResult {
        searches.append(question)
        return result
    }
}

@MainActor
final class LiveHintsJobManualsTests: XCTestCase {

    private let pumpJob = HintJobManuals(vaultId: "garden_pumps", vaultName: "Garden pumps",
                                         vaultOnly: false, citationsRequired: false)

    private let manualPassage = HintPassage(
        documentId: "doc-qmx", documentName: "QMX90 Pump Guide", chunkIndex: 2,
        text: "Status code QXRT means the impeller is blocked. Clear the intake basket and run the pump for 2 minutes.",
        citation: "QMX90 Pump Guide, page 12, §4 Status lights", page: 12)

    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveHintsJobManualsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Which documents

    func testDuringAJobTheJobsManualsAreTheDefault() {
        XCTAssertEqual(HintSearchScope.resolve(preference: .jobManualsWhenOpen, openJob: pumpJob, chosen: nil,
                                               activeProject: "proj-1"),
                       .jobManuals(pumpJob))
    }

    func testWithNoJobTheWearersDocumentsAreSearched() {
        XCTAssertEqual(HintSearchScope.resolve(preference: .jobManualsWhenOpen, openJob: nil, chosen: nil,
                                               activeProject: "proj-1"),
                       .personal(HintDocumentScope(namespace: "proj-1", documentIds: nil)))
    }

    func testMyDocumentsOrAPickedDocumentWinsOverTheJob() {
        XCTAssertEqual(HintSearchScope.resolve(preference: .myDocuments, openJob: pumpJob, chosen: nil, activeProject: nil),
                       .personal(HintDocumentScope(namespace: "global", documentIds: nil)))
        XCTAssertEqual(HintSearchScope.resolve(preference: .jobManualsWhenOpen, openJob: pumpJob, chosen: ["d1"],
                                               activeProject: nil),
                       .personal(HintDocumentScope(namespace: nil, documentIds: ["d1"])))
    }

    func testEachScopeHasItsOwnCacheKey() {
        let keys = [
            HintSearchScope.jobManuals(pumpJob).key,
            HintSearchScope.personal(HintDocumentScope(namespace: "global", documentIds: nil)).key,
            HintSearchScope.personal(HintDocumentScope(namespace: "proj-1", documentIds: nil)).key,
            HintSearchScope.personal(HintDocumentScope(namespace: nil, documentIds: ["b", "a"])).key,
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(HintSearchScope.personal(HintDocumentScope(namespace: nil, documentIds: ["b", "a"])).key,
                       HintSearchScope.personal(HintDocumentScope(namespace: nil, documentIds: ["a", "b"])).key)
    }

    // MARK: - The provider rule

    func testAManualHintAsksTheJobsModel() {
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: .anthropic, medicalLocalOnly: false),
                       .ask(allowGeneral: true))
    }

    func testNoPermittedModelIsThePassageCardAlone() {
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: nil, medicalLocalOnly: false),
                       .passageOnly(reason: "noPermittedModel"))
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: nil, medicalLocalOnly: true),
                       .passageOnly(reason: "noPermittedModel"))
    }

    func testMedicalLocalOnlyNeverSendsAManualPassageToTheCloud() {
        for provider in LLMProvider.allCases where !HintManualModelRule.runsOnPhone(provider) {
            XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: provider, medicalLocalOnly: true),
                           .passageOnly(reason: "medicalLocalOnly"), provider.rawValue)
        }
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: .local, medicalLocalOnly: true),
                       .ask(allowGeneral: true))
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: .appleOnDevice, medicalLocalOnly: true),
                       .ask(allowGeneral: true))
    }

    func testAVaultOnlyJobOrRequiredCitationsAnswerFromTheManualsAlone() {
        let sealed = HintJobManuals(vaultId: "v", vaultName: "V", vaultOnly: true, citationsRequired: false)
        let cited = HintJobManuals(vaultId: "v", vaultName: "V", vaultOnly: false, citationsRequired: true)
        XCTAssertEqual(HintManualModelRule.decide(job: sealed, resolvedProvider: .openai, medicalLocalOnly: false),
                       .ask(allowGeneral: false))
        XCTAssertEqual(HintManualModelRule.decide(job: cited, resolvedProvider: .openai, medicalLocalOnly: false),
                       .ask(allowGeneral: false))
        XCTAssertEqual(HintManualModelRule.decide(job: pumpJob, resolvedProvider: .openai, medicalLocalOnly: false,
                                                  sessionAllowsGeneral: false),
                       .ask(allowGeneral: false))
    }

    func testTheHintModelsOnPhoneRuleIsTheManualRules() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(LLMServiceHintModel.runsOnPhone(provider), HintManualModelRule.runsOnPhone(provider))
        }
    }

    // MARK: - The citation

    func testAManualHintNamesTheManualAndPageAndOpensThatPage() throws {
        let card = try XCTUnwrap(PassageHint.pick(from: [manualPassage], for: "What does status code QXRT mean?"))
        XCTAssertEqual(card.citation, "QMX90 Pump Guide, page 12, §4 Status lights")
        XCTAssertEqual(card.page, 12)
        let hint = LiveHintsService.passageHint(card, id: 1, question: "What does status code QXRT mean?",
                                                keyword: nil, askedAt: Date())
        XCTAssertEqual(hint.sourceLabel, "QMX90 Pump Guide, page 12, §4 Status lights")
        let citation = try XCTUnwrap(hint.manualCitation)
        XCTAssertEqual(citation.kind, .manual)
        XCTAssertEqual(citation.title, "QMX90 Pump Guide")
        XCTAssertEqual(citation.page, 12)
        XCTAssertEqual(citation.section, "4 Status lights")
    }

    func testAPersonalPassageHasNoManualPage() throws {
        let personal = HintPassage(documentId: "d", documentName: "Service terms", chunkIndex: 0,
                                   text: "The pump guarantee runs for 9 months from the fitting date.")
        let card = try XCTUnwrap(PassageHint.pick(from: [personal], for: "How long is the pump guarantee?"))
        XCTAssertNil(card.citation)
        XCTAssertNil(HintManualCitation.citation(for: card))
        XCTAssertEqual(card.sourceName, "Service terms")
    }

    func testTheModelIsShownTheCitationAsTheDocument() {
        let user = HintPromptBuilder.user(question: "What does QXRT mean?", earlierLines: [], passages: [manualPassage])
        XCTAssertTrue(user.contains(#"document="QMX90 Pump Guide, page 12, §4 Status lights""#), user)
    }

    // MARK: - The sheet

    func testTheDocumentsRowNamesTheJobsManualsByDefault() {
        let choices = LiveHintsSessionChoices.defaults(displayConnected: false)
        XCTAssertEqual(choices.documentSource, .jobManualsWhenOpen)
        XCTAssertEqual(HintDocumentsSummary.of(choices, openJob: pumpJob), .jobManuals(vaultName: "Garden pumps"))
        XCTAssertEqual(HintDocumentsSummary.of(choices, openJob: nil), .activeProject)
    }

    func testMyDocumentsIsTheAlternative() {
        var choices = LiveHintsSessionChoices()
        choices.documentSource = .myDocuments
        XCTAssertEqual(HintDocumentsSummary.of(choices, openJob: pumpJob), .activeProject)
        XCTAssertEqual(choices.settings.documentSource, .myDocuments)
        choices.documentSource = .jobManualsWhenOpen
        choices.documentIds = ["a", "b"]
        XCTAssertEqual(HintDocumentsSummary.of(choices, openJob: pumpJob), .picked(count: 2))
        XCTAssertEqual(choices.settings.documentSource, .myDocuments, "a picked document is a choice of my documents")
    }

    func testTheJobsManualsAreNamedEvenWithoutAVaultName() {
        XCTAssertEqual(LiveHintsCopy.jobManualsName(pumpJob), "Garden pumps")
        let unnamed = HintJobManuals(vaultId: "v", vaultName: "", vaultOnly: false, citationsRequired: false)
        XCTAssertEqual(LiveHintsCopy.jobManualsName(unnamed), LiveHintsCopy.jobManuals)
        XCTAssertFalse(LiveHintsCopy.jobManuals.contains("MO"))
    }

    // MARK: - The search adapter

    private func makeSearch(job: FakeJobManualSource, preference: HintSourcePreference = .jobManualsWhenOpen,
                            chosen: [String]? = nil, provider: LLMProvider? = .anthropic,
                            localOnly: Bool = false) -> JobAwareHintSearch {
        let store = DocumentStore(directory: tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true))
        let personal = DocumentStoreHintSearch(store: store, scope: {
            HintDocumentScope.resolve(chosen: chosen, activeProject: nil)
        })
        return JobAwareHintSearch(personal: personal, job: job, preference: { preference }, chosen: { chosen },
                                  activeProject: { nil }, resolvedProvider: { provider },
                                  medicalLocalOnly: { localOnly })
    }

    func testAnOpenJobIsSearchedThroughFieldAssist() {
        let job = FakeJobManualSource()
        job.hintJobManuals = pumpJob
        job.outcome = .passages([manualPassage])
        job.titles = ["QMX90 Pump Guide"]
        let search = makeSearch(job: job)
        let result = search.search(for: "What does QXRT mean?", limit: 4)
        XCTAssertEqual(job.questions, ["What does QXRT mean?"])
        XCTAssertEqual(result.passages, [manualPassage])
        XCTAssertEqual(result.modelUse, .ask(allowGeneral: true))
        XCTAssertEqual(result.scopeKey, "vault:garden_pumps")
        XCTAssertEqual(search.documentTitles(), ["QMX90 Pump Guide"])
    }

    func testNothingAnsweringInTheManualsIsNoCardAndNoCall() {
        let job = FakeJobManualSource()
        job.hintJobManuals = pumpJob
        job.outcome = .nothing(.insufficient)
        let result = makeSearch(job: job).search(for: "What does QXRT mean?", limit: 4)
        XCTAssertTrue(result.passages.isEmpty)
        XCTAssertEqual(result.modelUse, .passageOnly(reason: "manuals-insufficient"))
    }

    func testAJobClosedMidSessionGoesBackToTheWearersDocuments() {
        let job = FakeJobManualSource()
        job.hintJobManuals = pumpJob
        job.outcome = .passages([manualPassage])
        let search = makeSearch(job: job)
        XCTAssertEqual(search.search(for: "first question here", limit: 4).scopeKey, "vault:garden_pumps")
        job.hintJobManuals = nil
        let after = search.search(for: "second question here", limit: 4)
        XCTAssertEqual(after.scopeKey, "ns:global")
        XCTAssertEqual(after.modelUse, .ask(allowGeneral: true))
        XCTAssertEqual(job.questions, ["first question here"], "the job is not searched once it is closed")
        // And opened again: the next search is the job's.
        job.hintJobManuals = pumpJob
        XCTAssertEqual(search.search(for: "third question here", limit: 4).scopeKey, "vault:garden_pumps")
    }

    func testMyDocumentsDuringAJobNeverReachesTheManuals() {
        let job = FakeJobManualSource()
        job.hintJobManuals = pumpJob
        job.outcome = .passages([manualPassage])
        let result = makeSearch(job: job, preference: .myDocuments).search(for: "What does QXRT mean?", limit: 4)
        XCTAssertTrue(job.questions.isEmpty)
        XCTAssertFalse(result.passages.contains(manualPassage))
    }

    func testTheProviderRuleIsReadAtEverySearch() {
        let job = FakeJobManualSource()
        job.hintJobManuals = pumpJob
        job.outcome = .passages([manualPassage])
        XCTAssertEqual(makeSearch(job: job, provider: .openai, localOnly: true)
                        .search(for: "What does QXRT mean?", limit: 4).modelUse,
                       .passageOnly(reason: "medicalLocalOnly"))
        XCTAssertEqual(makeSearch(job: job, provider: nil).search(for: "What does QXRT mean?", limit: 4).modelUse,
                       .passageOnly(reason: "noPermittedModel"))
    }

    // MARK: - The session

    private var captions: FakeHintCaptions!
    private var model: FakeHintModel!
    private var lens: FakeHintLens!
    private var clock: FakeHintClock!

    private func makeService(documents: HintDocumentSearch) -> LiveHintsService {
        captions = FakeHintCaptions()
        model = FakeHintModel()
        lens = FakeHintLens()
        clock = FakeHintClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        model.clock = clock
        let service = LiveHintsService(carriers: .init(
            captions: captions, documents: documents, model: model, lens: lens, ear: FakeHintEar(),
            voiceActivity: FakeHintVoiceActivity(), phoneList: LiveHintsPhoneList(), clock: clock,
            allowance: FakeHintAllowance()))
        service.isEnabled = { true }
        service.firstRunAcknowledged = { true }
        service.setFirstRunAcknowledged = { _ in }
        return service
    }

    func testWhenTheRulesForbidTheCallThePassageCardStandsAlone() async {
        let documents = FakeScopedHintDocuments()
        documents.result = HintSearchResult(passages: [manualPassage], modelUse: .passageOnly(reason: "medicalLocalOnly"),
                                            scopeKey: "vault:garden_pumps")
        let service = makeService(documents: documents)
        service.start()
        captions.say("What does status code QXRT mean on this pump?")
        await service.waitUntilIdle()
        XCTAssertTrue(model.calls.isEmpty, "the passages never go to the model")
        XCTAssertEqual(lens.presented.map(\.source), [.passage])
        XCTAssertEqual(lens.presented.first?.sourceLabel, "QMX90 Pump Guide, page 12, §4 Status lights")
        XCTAssertEqual(service.modelCalls, 0)
    }

    func testNothingInTheManualsIsNoCardAtAll() async {
        let documents = FakeScopedHintDocuments()
        documents.result = HintSearchResult(passages: [], modelUse: .passageOnly(reason: "manuals-insufficient"),
                                            scopeKey: "vault:garden_pumps")
        let service = makeService(documents: documents)
        service.start()
        captions.say("What does status code QXRT mean on this pump?")
        await service.waitUntilIdle()
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertTrue(lens.presented.isEmpty)
        XCTAssertEqual(service.hintsShown, 0)
    }

    func testAManualHintWithGeneralKnowledgeOffTellsTheModelSo() async throws {
        let documents = FakeScopedHintDocuments()
        documents.result = HintSearchResult(passages: [manualPassage], modelUse: .ask(allowGeneral: false),
                                            scopeKey: "vault:garden_pumps")
        let service = makeService(documents: documents)
        service.start()
        captions.say("What does status code QXRT mean on this pump?")
        await service.waitUntilIdle()
        let call = try XCTUnwrap(model.calls.first)
        XCTAssertTrue(call.system.contains("Do not answer from general knowledge"), call.system)
        XCTAssertTrue(call.user.contains("QMX90 Pump Guide, page 12"), call.user)
    }

    func testKeywordCardsComeFromTheSameScopedSearch() async {
        let documents = FakeScopedHintDocuments()
        documents.result = HintSearchResult(passages: [manualPassage], modelUse: .ask(allowGeneral: true),
                                            scopeKey: "vault:garden_pumps")
        let service = makeService(documents: documents)
        service.start(.init(mode: .keyword, keywords: ["impeller"]))
        captions.say("The impeller looks fine to me today.")
        await service.waitUntilIdle()
        XCTAssertEqual(documents.searches, ["impeller"])
        XCTAssertEqual(lens.presented.first?.passage?.citation, manualPassage.citation)
    }

    // MARK: - During a procedure: the lens

    func testOverAStepCardAHintFlashesAndTheStepCardStays() {
        XCTAssertEqual(HintLensPlacement.decide(acceptsAnswerCard: false, taskCardShowing: true,
                                                lensDismissed: false, wearerLed: false), .overTask)
        XCTAssertEqual(HintLensPlacement.decide(acceptsAnswerCard: true, taskCardShowing: false,
                                                lensDismissed: false, wearerLed: false), .card)
        // A menu, an approval card or a page view: nothing on the lens.
        XCTAssertEqual(HintLensPlacement.decide(acceptsAnswerCard: false, taskCardShowing: false,
                                                lensDismissed: false, wearerLed: false), .none)
        // A lens the wearer dismissed stays dismissed, unless they asked.
        XCTAssertEqual(HintLensPlacement.decide(acceptsAnswerCard: false, taskCardShowing: true,
                                                lensDismissed: true, wearerLed: false), .none)
        XCTAssertEqual(HintLensPlacement.decide(acceptsAnswerCard: false, taskCardShowing: true,
                                                lensDismissed: true, wearerLed: true), .overTask)
    }

    func testTheFlashIsShorterThanACardAndCarriesNoButtons() {
        XCTAssertLessThan(HintLimits.overTaskFlashDuration, HintLimits.lensCardLifetime)
        let hint = LiveHint(id: 1, question: "What does status code QXRT mean?", keyword: nil,
                            line: "Impeller blocked: clear intake", full: "", spoken: "Impeller blocked",
                            source: .model, general: false, passage: nil, askedAt: Date())
        let flash = HintLensPlacement.flash(for: hint)
        XCTAssertEqual(flash.body, "Impeller blocked: clear intake")
        XCTAssertEqual(flash.title, HintQuestionGlance.glance("What does status code QXRT mean?"))
    }

    // MARK: - During a procedure: nothing of the hint moves a step

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Code with comments and string literals removed.
    private static func code(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return text
    }

    func testLiveHintsNeverDrivesAProcedureOrATaskCard() throws {
        let folder = Self.sourcesRoot.appendingPathComponent("Services/LiveHints")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        let forbidden = [
            "advanceProcedure", "procedureBack", "procedureRepeat", "answerProcedure", "confirmProcedureReadBack",
            "overrideProcedure", "completeProcedure", "startProcedure", "ProcedureRunner", "taskSource",
            "startTask", "endTask", ".complete()", ".skip()", ".back()", ".choose(",
        ]
        for url in files {
            let code = try Self.code(url)
            for name in forbidden {
                XCTAssertFalse(code.contains(name), "\(url.lastPathComponent) names \(name): a hint never moves a step")
            }
        }
        // The hint lens ends only its own card: `endInteractive` is reached through the serial check.
        let adapters = try Self.code(folder.appendingPathComponent("LiveHintsAdapters.swift"))
        let hide = try XCTUnwrap(adapters.range(of: "func hide(hintID: Int)"))
        let hideBody = String(adapters[hide.lowerBound...].prefix(400))
        XCTAssertTrue(hideBody.contains("heldAnswerCardSerial == HintLensCardBuilder.cardSerialBase + hintID"), hideBody)
    }

    // MARK: - During a procedure: the procedure's voice keeps priority

    func testNoStepWordIsALiveHintsCommand() {
        let stepWords = ProcedureVoiceDecider.repeatPhrases.union(ProcedureVoiceDecider.plainNextPhrases).union([
            "done", "next", "complete", "completed", "finish", "finished", "next step", "mark done",
            "skip", "skip this", "skip step", "back", "go back", "previous", "previous step", "step back",
            "yes", "no", "stop", "show me", "show", "hint", "what's the hint",
        ])
        for word in stepWords {
            XCTAssertNil(LiveHintsVoiceCommand.parse(word), "\"\(word)\" is the procedure's, never live hints'")
        }
    }

    func testTheNoModelProcedureTakesEveryUtteranceBeforeLiveHints() throws {
        let app = try Self.code(Self.sourcesRoot.appendingPathComponent("App/OpenGlassesApp.swift"))
        // String literals are blanked by `code`, so read the labels from the raw file.
        let raw = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("App/OpenGlassesApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("answerProcedureWithoutModel"))
        let procedure = try XCTUnwrap(raw.range(of: #"VoiceCommandHandler(label: "procedure-no-model")"#))
        let hints = try XCTUnwrap(raw.range(of: #"VoiceCommandHandler(label: "live-hints")"#))
        XCTAssertLessThan(procedure.lowerBound, hints.lowerBound,
                          "a procedure with no model hears every utterance before the live-hints phrases")
    }
}
