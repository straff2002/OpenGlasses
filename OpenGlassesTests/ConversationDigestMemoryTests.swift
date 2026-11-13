import XCTest
@testable import OpenGlasses

/// Plan LQ P3 — the way back: a fact names the conversation it came from while that conversation
/// is saved, Memory opens it to read without making it the open one, and the Conversations group
/// lists notes that forget like any fact. Headless: the "opening from Memory" check drives
/// `ChatThreadOpening`, the one piece of `ChatThreadView` that decides when a thread activates.
/// The facts and conversations are invented.
@MainActor
final class ConversationDigestMemoryTests: XCTestCase {

    private var dir: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var memory: SemanticMemoryStore!
    private var brain: BrainStore!
    private var notes: AgentDocumentStore!
    private var conversations: ConversationStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lq-memory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "ConversationDigestMemoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        PolicyEnvelope.clear()
        memory = SemanticMemoryStore(directory: dir)
        brain = BrainStore(directory: dir)
        notes = AgentDocumentStore(directory: dir)
        conversations = ConversationStore(directory: dir)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        memory = nil
        brain = nil
        conversations = nil
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func services() -> MemoryFactServices {
        let stores = MemoryFactStores(semantic: memory, brain: brain, agentDocuments: notes,
                                      conversations: conversations)
        var erasure = SubjectErasureCoordinator.Stores()
        erasure.brain = brain
        erasure.semanticMemory = memory
        erasure.agentDocuments = notes
        erasure.conversations = conversations
        return MemoryFactServices(stores: stores, coordinator: SubjectErasureCoordinator(stores: erasure))
    }

    /// A finished conversation about a fence, with a note.
    @discardableResult
    private func seedFenceConversation(note: Bool = true) -> String {
        let thread = conversations.startThread(mode: "direct")
        conversations.appendMessage(role: "user", content: "The back fence panel blew down in the wind.")
        conversations.appendMessage(role: "assistant", content: "A 6 ft panel and two posts should cover it.")
        conversations.appendMessage(role: "user", content: "I'll get Ben to help on Saturday.")
        conversations.appendMessage(role: "assistant", content: "Saturday it is.")
        if note {
            let last = conversations.threads.first { $0.id == thread.id }!.messages.last!.id
            _ = conversations.saveDigest(ConversationDigest(
                headline: "Back fence repair on Saturday",
                points: [.init(kind: .decided, text: "Ben helps with the fence on Saturday"),
                         .init(kind: .learned, text: "Needs a 6 ft panel and two posts")],
                coversThroughMessageID: last, writtenAt: Date(), tier: .cloud), for: thread.id)
        }
        conversations.endThread()
        return thread.id
    }

    // MARK: - Resolving the conversation

    func testASemanticFactAndAnAgentModeBrainFactResolveToTheirThread() throws {
        let thread = seedFenceConversation(note: false)
        XCTAssertTrue(memory.rememberGlobal("fence helper", value: "Ben", origin: .toldMe, sourceRef: thread))
        // Agent Mode's memory loop files the brain row as "memory-loop", with the thread as its session.
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", sourceRef: "memory-loop", sessionID: thread, origin: .toldMe)
        let facts = services().repository.load().facts
        let semantic = try XCTUnwrap(facts.first { $0.id.store == .semantic })
        let relation = try XCTUnwrap(facts.first { $0.id.store == .brainEdge })
        XCTAssertEqual(semantic.conversationThreadID, thread)
        XCTAssertEqual(relation.conversationThreadID, thread)
        XCTAssertEqual(relation.sourceRef, "memory-loop", "the session is read, not the source label")
    }

    func testABookFactResolvesToNone() throws {
        brain.addEdge(srcKind: "person", srcName: "Ada", relation: "works_at", dstKind: "org",
                      dstName: "Harbour Mill", sourceRef: "A Field Guide to Sheds", origin: .imported)
        let relation = try XCTUnwrap(services().repository.load().facts.first { $0.id.store == .brainEdge })
        XCTAssertNil(relation.conversationThreadID)
        XCTAssertNil(services().makeScreenModel().originatingConversation(for: relation))
    }

    func testADeletedThreadGivesNoRow() throws {
        let thread = seedFenceConversation(note: false)
        XCTAssertTrue(memory.rememberGlobal("fence helper", value: "Ben", origin: .toldMe, sourceRef: thread))
        let model = services().makeScreenModel()
        model.reload()
        let fact = try XCTUnwrap(model.listing.facts.first { $0.id.store == .semantic })
        let origin = try XCTUnwrap(model.originatingConversation(for: fact))
        XCTAssertEqual(origin.threadID, thread)
        XCTAssertEqual(origin.title, conversations.threads.first { $0.id == thread }?.title)

        conversations.deleteThread(thread)
        model.reload()
        let after = try XCTUnwrap(model.listing.facts.first { $0.id.store == .semantic })
        XCTAssertNil(after.conversationThreadID)
        XCTAssertNil(model.originatingConversation(for: after))
        XCTAssertNil(services().forgetter.plan(for: after).conversationThreadID,
                     "the forget plan reads the same resolved field")
    }

    // MARK: - Reading is not resuming

    func testOpeningFromMemoryLeavesTheActiveThreadUntilAMessageIsSent() {
        let old = seedFenceConversation()
        let current = conversations.startThread(mode: "direct").id
        let activate = { _ = self.conversations.resumeThread(old) }

        var fromMemory = ChatThreadOpening(activation: .onSend)
        fromMemory.appeared(activate: activate)
        XCTAssertEqual(conversations.activeThreadId, current, "reading a week-old conversation joins nothing")
        fromMemory.appeared(activate: activate)
        XCTAssertEqual(conversations.activeThreadId, current)

        // Sending is what every send path does first: `activateThread()`.
        activate()
        XCTAssertEqual(conversations.activeThreadId, old)

        _ = conversations.resumeThread(current)
        var fromChat = ChatThreadOpening(activation: .onAppear)
        var activations = 0
        fromChat.appeared { activations += 1; activate() }
        fromChat.appeared { activations += 1 }
        XCTAssertEqual(activations, 1, "the Chat tab activates once, on appear, as before")
        XCTAssertEqual(conversations.activeThreadId, old)
    }

    // MARK: - The Conversations group

    func testNotesAreListedUnderConversationsCollapsedAndForgetOnly() throws {
        let thread = seedFenceConversation()
        let model = services().makeScreenModel()
        model.reload()
        let section = try XCTUnwrap(model.sections.first { $0.group == .conversations })
        XCTAssertTrue(section.collapsedByDefault)
        let note = try XCTUnwrap(section.facts.first)
        XCTAssertEqual(note.text, "Back fence repair on Saturday")
        XCTAssertEqual(note.origin, .inferred)
        XCTAssertEqual(note.capabilities, .forget, "a derived note is never corrected")
        XCTAssertEqual(note.conversationThreadID, thread)
        XCTAssertEqual(note.details, ["Ben helps with the fence on Saturday", "Needs a 6 ft panel and two posts"])
        XCTAssertFalse(services().corrector.correct(note, to: "Something else").verified)
        XCTAssertTrue(MyMemoryToolScope.visible([note], activePersona: nil, agentModeEnabled: true).isEmpty,
                      "a note is found by a search, not read out as something known about the wearer")
        XCTAssertFalse(MemorySpokenSummary.summary([note]).contains("fence"))
    }

    func testForgettingANoteRedactsItAndOffersTheConversationsDelete() async throws {
        let thread = seedFenceConversation()
        let model = services().makeScreenModel()
        model.reload()
        let note = try XCTUnwrap(model.listing.facts.first { $0.id.store == .conversationDigest })
        model.requestForget(note)
        XCTAssertEqual(model.pendingForget?.conversationThreadID, thread)
        let confirmed = await model.confirmForget()
        let result = try XCTUnwrap(confirmed)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.conversationThreadID, thread, "the conversation's delete is offered")
        XCTAssertEqual(conversations.threads.first { $0.id == thread }?.digest?.isRedacted, true)
        XCTAssertFalse(model.listing.facts.contains { $0.id.store == .conversationDigest })
        XCTAssertTrue(conversations.threads.contains { $0.id == thread }, "never deleted without asking")

        let deleted = await model.deleteOriginatingConversation()
        XCTAssertTrue(deleted)
        XCTAssertFalse(conversations.threads.contains { $0.id == thread })
    }

    func testForgettingAFactOffersToRemoveTheNotePointsThatMentionIt() async throws {
        let thread = seedFenceConversation()
        XCTAssertTrue(memory.rememberGlobal("fence panel size", value: "6 ft panel", origin: .toldMe,
                                            sourceRef: thread))
        let s = services()
        let fact = try XCTUnwrap(s.repository.load().facts.first { $0.id.store == .semantic })
        let plan = s.forgetter.plan(for: fact)
        XCTAssertEqual(plan.digestPoints, [ConversationDigestPointReference(
            threadID: thread, text: "Needs a 6 ft panel and two posts")])

        let result = await s.forgetter.forget(plan, removeNoteLines: true)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(conversations.threads.first { $0.id == thread }?.digest?.points.map(\.text),
                       ["Ben helps with the fence on Saturday"])
    }

    func testKeepingTheNotePointsLeavesThem() async throws {
        let thread = seedFenceConversation()
        XCTAssertTrue(memory.rememberGlobal("fence panel size", value: "6 ft panel", origin: .toldMe,
                                            sourceRef: thread))
        let s = services()
        let fact = try XCTUnwrap(s.repository.load().facts.first { $0.id.store == .semantic })
        _ = await s.forgetter.forget(s.forgetter.plan(for: fact), removeNoteLines: false)
        XCTAssertEqual(conversations.threads.first { $0.id == thread }?.digest?.points.count, 2)
    }
}
