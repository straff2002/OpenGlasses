import XCTest
@testable import OpenGlasses

/// Plan GG P2 — the Memory screen's presentation: grouping, search, status rows, the empty state,
/// labels VoiceOver reads before the actions, and the forget flow's two steps.
@MainActor
final class MemoryScreenModelTests: XCTestCase {

    private var dir: URL!
    private var memory: SemanticMemoryStore!
    private var notes: AgentDocumentStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryScreenModel_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory = SemanticMemoryStore(directory: dir)
        notes = AgentDocumentStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func model(locked: Bool = false) -> MemoryScreenModel {
        var erasure = SubjectErasureCoordinator.Stores()
        erasure.semanticMemory = memory
        erasure.agentDocuments = notes
        let services = MemoryFactServices(
            stores: MemoryFactStores(semantic: memory, agentDocuments: notes),
            coordinator: SubjectErasureCoordinator(stores: erasure),
            protectedDataAvailable: { !locked })
        let model = services.makeScreenModel()
        model.reload()
        return model
    }

    func testEmptyStateWhenNothingIsSaved() {
        let m = model()
        XCTAssertTrue(m.showsEmptyState)
        XCTAssertTrue(m.sections.isEmpty)
    }

    func testLockedShowsStatusNotTheEmptyState() {
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        let m = model(locked: true)
        XCTAssertFalse(m.showsEmptyState, "locked is not the same as nothing saved")
        XCTAssertTrue(m.sections.isEmpty, "no stale rows while locked")
        XCTAssertEqual(m.statusMessages.count, 2)
        XCTAssertTrue(m.statusMessages.allSatisfy { $0.contains("unlock") })
    }

    func testSectionsGroupAndHealthStartsCollapsed() {
        XCTAssertTrue(memory.rememberGlobal("favourite tea", value: "earl grey", origin: .toldMe))
        XCTAssertTrue(memory.rememberGlobal("knee", value: "left knee surgery", origin: .toldMe))
        memory.writeDiary("Seems to prefer short answers")
        let m = model()
        XCTAssertEqual(m.sections.map(\.group), [.preferences, .other, .health])
        XCTAssertTrue(m.sections.last?.collapsedByDefault == true)
        XCTAssertFalse(m.healthExpanded)
        XCTAssertTrue(m.sections.first { $0.group == .other }?.facts.first?.origin.isInferred == true,
                      "diary observations carry the inferred badge")
    }

    func testSearchFiltersSections() {
        XCTAssertTrue(memory.rememberGlobal("favourite tea", value: "earl grey", origin: .toldMe))
        XCTAssertTrue(memory.rememberGlobal("home city", value: "Wellington", origin: .toldMe))
        let m = model()
        m.query = "wellington"
        XCTAssertEqual(m.visibleFacts.map(\.correctableValue), ["Wellington"])
        XCTAssertEqual(m.sections.map(\.group), [.places])
    }

    func testAccessibilityLabelReadsOriginBeforeActions() {
        let fact = MemoryFact(id: MemoryFactID(store: .semantic, recordID: "global:tea"),
                              text: "favourite tea: earl grey", kind: .semantic(topic: "preferences"),
                              origin: .inferred, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let label = MemoryScreenModel.accessibilityLabel(for: fact)
        XCTAssertTrue(label.hasPrefix("favourite tea: earl grey. Inferred."), label)
        XCTAssertFalse(MemoryScreenModel.originLabel(.legacyUnknown).localizedCaseInsensitiveContains("told"),
                       "an unknown origin is never presented as told")
    }

    func testForgetIsTwoStepAndReloads() async throws {
        XCTAssertTrue(memory.rememberGlobal("home city", value: "Wellington", origin: .toldMe))
        notes.appendMemory("Lives near Wellington harbour")
        let m = model()
        let fact = try XCTUnwrap(m.listing.facts.first { $0.id.store == .semantic })
        m.requestForget(fact)
        let plan = try XCTUnwrap(m.pendingForget)
        XCTAssertEqual(plan.noteLines.count, 1, "the matching note line is shown before removal")
        XCTAssertNotNil(memory.recall("home city"), "requesting is not forgetting")

        m.removeNoteLines = false
        let confirmed = await m.confirmForget()
        let result = try XCTUnwrap(confirmed)
        XCTAssertTrue(result.verified)
        XCTAssertNil(m.pendingForget)
        XCTAssertFalse(m.listing.facts.contains { $0.id == fact.id }, "the list reloads from the store")
        XCTAssertTrue(notes.content(for: .memory).contains("harbour"), "lines kept when not chosen")
    }

    func testCancelLeavesEverythingInPlace() throws {
        XCTAssertTrue(memory.rememberGlobal("home city", value: "Wellington", origin: .toldMe))
        let m = model()
        m.requestForget(try XCTUnwrap(m.listing.facts.first))
        m.cancelForget()
        XCTAssertNil(m.pendingForget)
        XCTAssertEqual(memory.recall("home city"), "Wellington")
    }
}
