import XCTest
@testable import OpenGlasses

/// Plan GG P3 — the voice route: one match acts, several go to the phone, none says so; Health is
/// not read aloud unprompted; forgetting asks first.
@MainActor
final class MyMemoryToolTests: XCTestCase {

    private var dir: URL!
    private var memory: SemanticMemoryStore!
    private var brain: BrainStore!
    private var services: MemoryFactServices!
    private var confirmations: [String] = []
    private var handOffs: [String] = []

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyMemoryTool_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory = SemanticMemoryStore(directory: dir)
        brain = BrainStore(directory: dir)
        var erasure = SubjectErasureCoordinator.Stores()
        erasure.semanticMemory = memory
        erasure.brain = brain
        services = MemoryFactServices(stores: MemoryFactStores(semantic: memory, brain: brain),
                                      coordinator: SubjectErasureCoordinator(stores: erasure))
        confirmations = []
        handOffs = []
    }

    override func tearDown() {
        // Release the stores (and the services holding them), closing their SQLite connections,
        // before their files are unlinked.
        services = nil
        memory = nil
        brain = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func tool(approve: Bool? = true) -> MyMemoryTool {
        var tool = MyMemoryTool()
        let services = services!
        tool.facts = { services.repository.load().facts }
        tool.forgetter = services.forgetter
        tool.corrector = services.corrector
        if let approve {
            tool.confirm = { [weak self] summary in
                self?.confirmations.append(summary)
                return approve
            }
        }
        tool.handOff = { [weak self] query in self?.handOffs.append(query) }
        return tool
    }

    private func seed() {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        XCTAssertTrue(memory.rememberGlobal("favourite tea", value: "earl grey", origin: .toldMe))
        XCTAssertTrue(memory.rememberGlobal("knee injury", value: "left knee surgery in 2024", origin: .toldMe))
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "works_at", dstKind: "org",
                      dstName: "Acme", origin: .toldMe)
    }

    func testListSummarisesCountsAndThreeRecentWithoutHealth() async throws {
        seed()
        let reply = try await tool().execute(args: ["action": "list"])
        XCTAssertTrue(reply.contains("I know 3 things about you"), reply)
        XCTAssertTrue(reply.contains("Memory on your phone"))
        XCTAssertFalse(reply.localizedCaseInsensitiveContains("knee"), "Health is never read unprompted: \(reply)")
    }

    func testAboutAPersonReadsTheirFacts() async throws {
        seed()
        let reply = try await tool().execute(args: ["action": "about", "subject": "Maria"])
        XCTAssertTrue(reply.contains("Maria works at Acme"), reply)
    }

    func testHealthOnlyWhenAskedAboutHealth() async throws {
        seed()
        let unprompted = try await tool().execute(args: ["action": "about", "subject": "knee"])
        XCTAssertFalse(unprompted.contains("surgery"), unprompted)
        let asked = try await tool().execute(args: ["action": "about", "subject": "my knee health"])
        XCTAssertTrue(asked.contains("surgery"), asked)
    }

    func testForgetOneMatchConfirmsWithTheFactThenForgets() async throws {
        seed()
        let reply = try await tool().execute(args: ["action": "forget", "fact": "my sister lives in Wellington"])
        XCTAssertEqual(confirmations, ["Forget \u{201C}sister city: Wellington\u{201D}?"])
        XCTAssertTrue(reply.hasPrefix("Forgotten."), reply)
        XCTAssertNil(memory.recall("sister city"))
    }

    func testForgetDeclinedKeepsTheFact() async throws {
        seed()
        let reply = try await tool(approve: false).execute(args: ["action": "forget", "fact": "sister Wellington"])
        XCTAssertEqual(reply, "Okay, I've kept it.")
        XCTAssertEqual(memory.recall("sister city"), "Wellington")
    }

    func testForgetWithoutConfirmationFailsClosed() async throws {
        seed()
        let reply = try await tool(approve: nil).execute(args: ["action": "forget", "fact": "sister Wellington"])
        XCTAssertTrue(reply.contains("confirmation"), reply)
        XCTAssertEqual(memory.recall("sister city"), "Wellington")
    }

    func testForgetManyMatchesHandsOffToThePhoneAndForgetsNothing() async throws {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        XCTAssertTrue(memory.rememberGlobal("brother city", value: "Wellington", origin: .toldMe))
        let reply = try await tool().execute(args: ["action": "forget", "fact": "city Wellington"])
        XCTAssertTrue(reply.contains("I found two"), reply)
        XCTAssertTrue(confirmations.isEmpty, "nothing is confirmed when nothing is resolved")
        XCTAssertEqual(handOffs, ["city Wellington"])
        XCTAssertEqual(memory.recall("sister city"), "Wellington")
        XCTAssertEqual(memory.recall("brother city"), "Wellington")
    }

    func testForgetNoMatchSaysSo() async throws {
        seed()
        let reply = try await tool().execute(args: ["action": "forget", "fact": "my favourite colour"])
        XCTAssertEqual(reply, "I couldn't find that in what I remember.")
    }

    func testCorrectOneMatchUpdatesWithoutAsking() async throws {
        seed()
        let reply = try await tool().execute(args: ["action": "correct", "fact": "sister lives in Wellington",
                                                    "new_value": "Nelson"])
        XCTAssertTrue(reply.hasPrefix("Updated."), reply)
        XCTAssertEqual(memory.recall("sister city"), "Nelson")
        XCTAssertTrue(confirmations.isEmpty)
    }

    func testScopeHidesOtherPersonasAndNotesOutsideAgentMode() {
        let shared = MemoryFact(id: MemoryFactID(store: .semantic, recordID: "global:a"), text: "a",
                                kind: .semantic(topic: "general"), origin: .toldMe, createdAt: Date())
        let mine = MemoryFact(id: MemoryFactID(store: .semantic, recordID: "coach:b"), text: "b",
                              kind: .semantic(topic: "general"), origin: .toldMe, createdAt: Date(),
                              persona: "coach")
        let theirs = MemoryFact(id: MemoryFactID(store: .semantic, recordID: "docent:c"), text: "c",
                                kind: .semantic(topic: "general"), origin: .toldMe, createdAt: Date(),
                                persona: "docent")
        let note = MemoryFact(id: MemoryFactID(store: .agentNote, recordID: "n"), text: "n",
                              kind: .agentNote, origin: .legacyUnknown, createdAt: Date())
        let all = [shared, mine, theirs, note]
        XCTAssertEqual(MyMemoryToolScope.visible(all, activePersona: "coach", agentModeEnabled: false).map(\.text),
                       ["a", "b"])
        XCTAssertEqual(MyMemoryToolScope.visible(all, activePersona: nil, agentModeEnabled: true).map(\.text),
                       ["a", "n"])
    }
}
