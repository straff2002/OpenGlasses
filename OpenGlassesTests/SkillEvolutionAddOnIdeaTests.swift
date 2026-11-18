import XCTest
import SQLite3
@testable import OpenGlasses

/// The suggestions inbox's second kind of proposal: "Build an add-on for: …?", only when the
/// failures are mostly "no tool could get it", stored with its kind, and nothing fetched before
/// Build it. Plus the store's `kind` migration.
@MainActor
final class SkillEvolutionAddOnIdeaTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillEvolutionAddOnIdeaTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeStore() -> EvolvedSkillStore { EvolvedSkillStore(directory: root) }

    private struct StubAnalyzer: SkillEvolutionAnalyzer {
        let output: String?
        func analyze(_ samples: [FailureSample]) async -> String? { output }
    }

    private func cannot(_ prompt: String) -> FailureSample {
        FailureSample(kind: .userCorrection, prompt: prompt,
                      response: "Sorry, I don't have a tool that can look up live tide times.",
                      userCorrection: "that's not helpful", at: Date())
    }

    private func wrong(_ prompt: String) -> FailureSample {
        FailureSample(kind: .userCorrection, prompt: prompt, response: "It's 22 degrees.",
                      userCorrection: "no, I meant Fahrenheit", at: Date())
    }

    private func withAgentMode(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let key = "agentModeEnabled"
        let prior = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        UserDefaults.standard.set(on, forKey: key)
        try await body()
    }

    // MARK: - The classifier

    func testABatchOfMissingCapabilitiesIsDominated() {
        XCTAssertTrue(AddOnIdeaClassifier.isDominatedByMissingCapability(
            [cannot("tide at Plimmerton"), cannot("tide at Raglan"), cannot("tide tomorrow")]))
        XCTAssertTrue(AddOnIdeaClassifier.isDominatedByMissingCapability(
            [cannot("a"), cannot("b"), cannot("c"), wrong("d")]))
        XCTAssertFalse(AddOnIdeaClassifier.isDominatedByMissingCapability(
            [cannot("a"), wrong("b"), wrong("c")]))
        XCTAssertFalse(AddOnIdeaClassifier.isDominatedByMissingCapability([cannot("a"), cannot("b")]),
                       "too few to call it a pattern")
    }

    func testIdeasAreReadFromOneLine() {
        XCTAssertEqual(AddOnIdeaClassifier.idea(in: "addon-idea: tide times at the coast"), "tide times at the coast")
        XCTAssertEqual(AddOnIdeaClassifier.idea(in: "  Addon-Idea: \"ferry status\"\nanything else"), "ferry status")
        XCTAssertNil(AddOnIdeaClassifier.idea(in: "name: x\ntrigger: t\ninstruction: i"))
        XCTAssertNil(AddOnIdeaClassifier.idea(in: "addon-idea: x"))
        XCTAssertLessThanOrEqual(AddOnIdeaClassifier.idea(in: "addon-idea: " + String(repeating: "tide ", count: 60))?.count ?? 0,
                                 AddOnIdeaClassifier.maxGoalLength)
    }

    func testThePromptOffersIdeasOnlyForADominatedBatch() {
        let dominated = [cannot("a"), cannot("b"), cannot("c")]
        XCTAssertTrue(SkillEvolutionPrompt.systemPrompt(for: dominated).contains("addon-idea:"))
        XCTAssertFalse(SkillEvolutionPrompt.systemPrompt(for: [wrong("a"), wrong("b"), wrong("c")]).contains("addon-idea:"))
    }

    // MARK: - The service

    func testADominatedBatchEnqueuesAnIdeaOfItsOwnKind() async {
        await withAgentMode(true) {
            let store = makeStore()
            let service = SkillEvolutionService(store: store)
            service.batchThreshold = 3
            service.analyzer = StubAnalyzer(output: "addon-idea: tide times at the coast")
            for prompt in ["tide at Plimmerton", "tide at Raglan", "tide tomorrow"] { service.record(cannot(prompt)) }
            let draft = await service.evolveIfNeeded()
            XCTAssertNil(draft, "an idea is not a voice skill")
            let pending = store.pending()
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending.first?.kind, .addOnIdea)
            XCTAssertEqual(pending.first?.addOnGoal, "tide times at the coast")
            XCTAssertTrue(store.activeDrafts().isEmpty, "ideas never dedupe voice skills")

            // Approving it as a voice skill does nothing: it can only be built or dismissed.
            service.approve(id: pending[0].id)
            XCTAssertEqual(store.pending().count, 1)
        }
    }

    func testAnIdeaIsIgnoredWhenTheBatchIsNotAboutMissingTools() async {
        await withAgentMode(true) {
            let store = makeStore()
            let service = SkillEvolutionService(store: store)
            service.batchThreshold = 3
            service.analyzer = StubAnalyzer(output: "addon-idea: weather in fahrenheit")
            for prompt in ["a", "b", "c"] { service.record(wrong(prompt)) }
            _ = await service.evolveIfNeeded()
            XCTAssertTrue(store.pending().isEmpty)
        }
    }

    func testTheSameIdeaIsNeverSuggestedTwice() {
        let store = makeStore()
        XCTAssertTrue(store.enqueueAddOnIdea(goal: "tide times at the coast"))
        store.dismiss(id: store.pending()[0].id)
        XCTAssertFalse(store.enqueueAddOnIdea(goal: "tide times at the coast"))
    }

    func testBuildItStartsANormalSessionAndNothingBefore() async throws {
        let store = makeStore()
        store.enqueueAddOnIdea(goal: "tide times at the coast")
        let idea = try XCTUnwrap(store.pending().first)
        let model = ScriptedAuthoringModel()
        model.replies = [#"{"action":"give_up","reason":"none"}"#]
        let docs = FakeDocsFetcher()
        let addOns = AddOnStore(directory: root.appendingPathComponent("addons"), backupDirectory: root)
        let authoring = AddOnAuthoringService(
            store: addOns, drafts: AddOnDraftStore(directory: root.appendingPathComponent("drafts"), backupDirectory: root),
            install: AddOnInstallService(store: addOns, context: { .init() }, fetch: { _ in Data() },
                                         networkDecision: .allowHardenedFetch),
            dependencies: .init(model: model, search: { _ in "" }, docs: docs,
                                transport: FakeAddOnHTTPTransport(json: "{}"), consent: { _ in .declined },
                                conditions: { .init(agentModeEnabled: true) },
                                runContext: { _ in RecipeRunContext(now: Date(), timeZone: .current, locale: .current,
                                                                    units: .metric, location: nil) }))
        XCTAssertTrue(model.calls.isEmpty, "a suggestion fetches and asks nothing on its own")

        let service = SkillEvolutionService(store: store)
        let message = service.buildAddOn(id: idea.id, with: authoring)
        XCTAssertEqual(message, "I'll look for a free public service for that, and I'll ask you before I test anything.")
        XCTAssertTrue(store.pending().isEmpty, "the idea leaves the inbox once it is being built")
        await authoring.waitForSession()
        XCTAssertEqual(model.calls.count, 1)
        XCTAssertTrue(model.calls[0].user.contains("tide times at the coast"))
    }

    func testBuildItIsRefusedWithoutTheBuilder() {
        let store = makeStore()
        store.enqueueAddOnIdea(goal: "ferry status")
        let id = store.pending()[0].id
        XCTAssertEqual(SkillEvolutionService(store: store).buildAddOn(id: id, with: nil),
                       "Building add-ons isn't available right now.")
        XCTAssertEqual(store.pending().count, 1)
    }

    // MARK: - Migration

    func testAnOlderDatabaseGainsTheKindColumnAndKeepsItsRowsAsVoiceSkills() throws {
        let url = root.appendingPathComponent("evolved_skills.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let legacy = """
        CREATE TABLE evolved_skills (
            id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, trigger_text TEXT NOT NULL,
            instruction TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
            created_at REAL NOT NULL, resolved_at REAL);
        INSERT INTO evolved_skills VALUES ('old-1', 'expense-tagging', 'expense this', 'tag it', 'pending', 1.0, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = makeStore()
        XCTAssertTrue(store.columnNames().contains("kind"))
        let rows = store.pending()
        XCTAssertEqual(rows.map(\.id), ["old-1"])
        XCTAssertEqual(rows.first?.kind, .voiceSkill)
        XCTAssertTrue(store.enqueueAddOnIdea(goal: "tide times"))
        XCTAssertEqual(Set(store.pending().map(\.kind)), [.voiceSkill, .addOnIdea])

        // Opening it again changes nothing.
        let again = makeStore()
        XCTAssertEqual(again.pending().count, 2)
    }

    func testANewDatabaseHasTheColumnFromTheStart() {
        XCTAssertTrue(makeStore().columnNames().contains("kind"))
    }
}
