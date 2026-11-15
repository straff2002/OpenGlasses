import XCTest
@testable import OpenGlasses

/// Plan LU P1 — one private Direct conversation, end to end at the highest seams that run
/// headless: a start by phrase, a follow-up, a `[REMEMBER…]` tag in the reply, a `remember_scene`
/// call, a reminder, then the end. Afterwards no store holds a word of it, the activity trail has
/// titles only, the reminder ran, and the stored conversation open before it is unchanged and still
/// active.
///
/// What it cannot run is `AppState` itself (a test host never configures the glasses SDK, and an
/// `AppState` turn reaches the camera and the HUD). So the turn's own steps are driven here in the
/// order `handleTranscription` takes them — the phrase match, `beginPrivate`'s three moves, the
/// transcript in place of the store, the reply's memory pass, the tools through the router, the
/// trail and trace writes, and the end's three moves back — against real stores in a temp
/// directory. `PrivateConversationSinkGuardTests` pins that the app's own call sites take them.
@MainActor
final class PrivateConversationTraceTests: XCTestCase {

    private final class Spy { var count = 0 }

    private struct SpyTool: NativeTool {
        let name: String
        let spy: Spy
        let description = "spy"
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .read() }
        func execute(args: [String: Any]) async throws -> String {
            spy.count += 1
            return "ran:\(name)"
        }
    }

    private var directory: URL!
    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        PrivateConversationGate.setActive(false)
        savedAgentMode = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateConversationTraceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        PrivateConversationGate.setActive(false)
        Config.setAgentModeEnabled(savedAgentMode)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func folder(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One line per thread: id, title and every message, so "unchanged" means unchanged.
    private func fingerprint(_ store: ConversationStore) -> [String] {
        store.threads.map { thread in
            ([thread.id, thread.title] + thread.messages.map { "\($0.role):\($0.content)" })
                .joined(separator: "|")
        }
    }

    /// Every byte this test's stores wrote, as text, for the words that must not be there.
    private func everythingOnDisk() throws -> String {
        var text = ""
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let data = try Data(contentsOf: url)
            text += String(decoding: data, as: UTF8.self)
        }
        return text
    }

    func testAPrivateDirectConversationLeavesNothingOfItsWordsBehind() async throws {
        // The conversation open before: stored, active, and in the model's context.
        let store = ConversationStore(directory: folder("conversations"))
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "What's on this afternoon?")
        store.appendMessage(role: "assistant", content: "Two meetings.")
        let storedBefore = fingerprint(store)
        let activeBefore = store.activeThreadId
        XCTAssertNotNil(activeBefore)

        let memory = SemanticMemoryStore(directory: folder("memory"))
        XCTAssertTrue(memory.remember("parking spot", value: "level three"))
        let activity = ActivityStore(directory: folder("activity"), hipaaMode: { false },
                                     hipaaRetentionDays: { nil })
        let traces = TurnTraceStore(url: directory.appendingPathComponent("traces/turn-traces.json"))
        let llm = LLMService()
        llm.recordExternalExchange(user: "What's on this afternoon?", assistant: "Two meetings.")
        let contextBefore = llm.conversationHistoryForTesting().map { "\($0.role):\($0.content)" }
        let bridge = OpenClawBridge()
        let stableKey = bridge.currentSessionKey

        let registry = NativeToolRegistry(locationService: LocationService())
        let sceneSpy = Spy(), reminderSpy = Spy()
        registry.register(SpyTool(name: "remember_scene", spy: sceneSpy))
        registry.register(SpyTool(name: "reminder", spy: reminderSpy))
        let router = NativeToolRouter(registry: registry)

        let controller = PrivateConversationController()

        // 1. The start, by phrase: matched before anything is saved.
        let utterance = "Off the record, is a mole that's changed shape something to see a doctor about?"
        guard case .start(.question(let question)) = PrivateStartPhrase.match(utterance) else {
            return XCTFail("the phrase should start a private conversation with its question")
        }
        XCTAssertNil(controller.begin(entry: .voicePhrase, conditions: PrivateStartConditions()))
        llm.beginPrivateHistory(controller.transcript.replayMessages())
        bridge.beginPrivateSession()
        XCTAssertTrue(PrivateConversationGate.isActive)
        XCTAssertTrue(llm.conversationHistoryForTesting().isEmpty)
        XCTAssertNotEqual(bridge.effectiveSessionKey, stableKey)

        // 2. The first private turn, with tags the model should not have written.
        controller.append(role: "user", content: question)
        let firstReply = memory.parseAndExecuteCommands(
            in: "It's worth having it looked at. [REMEMBER: worry = a mole that changed shape] "
                + "[DIARY: The wearer asked about a mole.]",
            userUtterance: question, threadID: store.activeThreadId)
        XCTAssertEqual(firstReply, "It's worth having it looked at.", "the tags are still stripped")
        controller.append(role: "assistant", content: firstReply)
        llm.recordExternalExchange(user: question, assistant: firstReply)

        // 3. A follow-up asking to remember, and a forget that must still work.
        let followUp = "Remember to book the GP"
        controller.append(role: "user", content: followUp)
        let secondReply = memory.parseAndExecuteCommands(
            in: "Noted. [REMEMBER_GLOBAL: appointment = book the GP] [FORGET: parking spot]",
            userUtterance: followUp, threadID: store.activeThreadId)
        XCTAssertTrue(secondReply.hasSuffix(PrivateConversationLines.wontRemember), secondReply)
        XCTAssertFalse(secondReply.contains("["), secondReply)
        XCTAssertNil(memory.recall("appointment"))
        XCTAssertNil(memory.recall("parking spot"), "forgetting is never blocked")
        controller.append(role: "assistant", content: secondReply)
        llm.recordExternalExchange(user: followUp, assistant: secondReply)
        XCTAssertEqual(llm.conversationHistoryForTesting().count, 4, "the follow-up sees the first turn")
        XCTAssertEqual(controller.transcript.count, 4)

        // 4. The tools: memory-like refused before anything runs, the reminder runs.
        let scene = await router.executeRoot(name: "remember_scene", args: ["label": "the mole"])
        XCTAssertEqual(scene, .rejected(reason: PrivateToolRule.refusalReason))
        XCTAssertEqual(sceneSpy.count, 0)
        let reminder = await router.executeRoot(name: "reminder",
                                                args: ["action": "create", "title": "Book the GP"])
        XCTAssertEqual(reminder, .completed("ran:reminder"))
        XCTAssertEqual(reminderSpy.count, 1, "a reminder the wearer asks for is kept (decision 2)")

        // 5. The trail and the trace the turn leaves.
        activity.append(ActivityEntry(id: UUID(), at: Date(), kind: .action, title: "Set a reminder",
                                      detail: "Reminder: Book the GP about the mole", tool: "reminder",
                                      authorisation: .asked, origin: .wearer, outcome: .done))
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: Date())
        timeline.threadId = store.activeThreadId
        timeline.manualPassages = ["a manual about moles, page 3"]
        timeline.toolCalls = [.init(name: "web_search", outcome: "completed",
                                    search: .init(query: "mole changed shape", result: "see a doctor about the mole"))]
        traces.append(TurnTrace(timeline, sealedAt: Date()))

        // 6. The glanceable surfaces while it is open.
        XCTAssertEqual(LiveActivityManager.snippet(firstReply, placeholder: PrivateConversationGate.placeholder(
            for: .liveActivitySnippet)), PrivateConversationPolicy.placeholderText)
        XCTAssertEqual(WatchConnectivityManager.lastResponsePayload(firstReply, placeholder: PrivateConversationGate
            .placeholder(for: .watchLastResponse)), PrivateConversationPolicy.placeholderText)
        XCTAssertFalse(CameraService.filesCaptureToLibrary(
            explicitPhoto: false, skipsPhotoTurn: PrivateConversationGate.skips(.photoTurnToLibrary)),
            "a photo taken to answer a question is not filed in Photos")
        XCTAssertTrue(CameraService.filesCaptureToLibrary(
            explicitPhoto: true, skipsPhotoTurn: PrivateConversationGate.skips(.photoTurnToLibrary)),
            "a photo the wearer asked to take is")

        // 7. The end.
        XCTAssertTrue(controller.end(.endPhrase))
        llm.endPrivateHistory()
        bridge.endPrivateSession()

        // Nothing of its words anywhere.
        XCTAssertTrue(controller.transcript.isEmpty)
        XCTAssertFalse(PrivateConversationGate.isActive)
        traces.waitForPendingWrites()
        let disk = try everythingOnDisk().lowercased()
        for word in ["mole", "book the gp", "worry", "appointment", "doctor"] {
            XCTAssertFalse(disk.contains(word), "'\(word)' was written somewhere")
        }
        XCTAssertTrue(memory.readDiary().isEmpty)
        XCTAssertFalse(memory.allEntries().contains { "\($0.keyName) \($0.value)".lowercased().contains("mole") })
        XCTAssertEqual(activity.entries.count, 1)
        XCTAssertEqual(activity.entries.first?.title, "Set a reminder", "the trail keeps the title")
        XCTAssertNil(activity.entries.first?.detail, "and only the title")
        let trace = try XCTUnwrap(traces.all.first)
        XCTAssertNil(trace.threadId)
        XCTAssertTrue(trace.manualPassages.isEmpty)
        XCTAssertEqual(trace.toolCalls.map(\.name), ["web_search"], "the trace keeps its shape")
        XCTAssertNil(trace.toolCalls.first?.search, "but none of its text")

        // The conversation open before: unchanged, still active, its context back as it was.
        XCTAssertEqual(fingerprint(store), storedBefore)
        XCTAssertEqual(store.activeThreadId, activeBefore)
        XCTAssertEqual(llm.conversationHistoryForTesting().map { "\($0.role):\($0.content)" }, contextBefore)
        XCTAssertEqual(bridge.effectiveSessionKey, stableKey)

        // And after it, everything keeps what it keeps again.
        activity.append(ActivityEntry(id: UUID(), at: Date(), kind: .action, title: "Set a timer",
                                      detail: "Timer: 10 minutes", tool: "set_timer",
                                      authorisation: .asked, origin: .wearer, outcome: .done))
        XCTAssertEqual(activity.entries.last?.detail, "Timer: 10 minutes")
        let ordinary = await router.executeRoot(name: "remember_scene", args: ["label": "the desk"])
        XCTAssertEqual(ordinary, .completed("ran:remember_scene"))
    }

    /// The prompt line the model is given for a private turn, and only for one.
    func testThePrivateTurnsPromptLineSaysNothingIsKept() {
        XCTAssertEqual(SystemPromptBuilder.privateConversationLine,
                       "This conversation is private. Don't use memory tags. Nothing from it is kept.")
    }

    /// The Live Activity and the watch show the reply whenever no private conversation is open.
    func testOrdinaryRepliesStillShowOnTheGlanceableSurfaces() {
        let reply = String(repeating: "Sunny with a light breeze. ", count: 12)
        XCTAssertEqual(LiveActivityManager.snippet(reply, placeholder: PrivateConversationGate.placeholder(
            for: .liveActivitySnippet)), String(reply.prefix(80)))
        XCTAssertEqual(WatchConnectivityManager.lastResponsePayload(reply, placeholder: PrivateConversationGate
            .placeholder(for: .watchLastResponse)), String(reply.prefix(200)))
    }
}
