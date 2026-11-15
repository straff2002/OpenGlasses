import XCTest
@testable import OpenGlasses

/// Plan LU §3 — the test that catches the *next* writer that forgets a private conversation.
///
/// The behavioural tests ask "does each sink skip when it is asked?". This one asks the question
/// they cannot: "is it asked everywhere?" It reads `OpenGlasses/Sources`, in the style of
/// `OutboundFrameConsumerTests`, and fails when:
/// - a conversation-store write (`startThread(`, `appendMessage(`, `continueRecentOrStartThread(`)
///   sits outside the reach of the persistence helper (`persistsConversation`, or a turn's
///   `turnPersists`) and is not on the short, justified roster below;
/// - a writer that consults the gate itself — the memory tags, the nudge, the memory loop, skill
///   evolution, the gateway's memory, the turn traces, the activity trail, the Photos sink, the
///   glanceable surfaces, the bridges, the recogniser, the router, the system prompt — no longer
///   names it in its own body;
/// - anything but the controller writes the gate, or anything but `AppState`'s private-conversation
///   file starts or ends one.
final class PrivateConversationSinkGuardTests: XCTestCase {

    // MARK: - Source reading

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    private struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let text: String
        var description: String { "\(file):\(line): \(text)" }
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourcesRoot,
                                                                      includingPropertiesForKeys: nil))
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" { files.append(url) }
        XCTAssertGreaterThan(files.count, 100, "the scan found the sources")
        return files
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    }

    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    /// Every code line in the sources containing `pattern`, declarations excluded.
    private func hits(of pattern: String) throws -> [Hit] {
        var found: [Hit] = []
        for url in try swiftFiles() {
            for (index, line) in try lines(of: url).enumerated()
            where line.contains(pattern) && !Self.isComment(line) && !line.contains("func ") {
                found.append(Hit(file: url.lastPathComponent, line: index + 1,
                                 text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    private func file(_ name: String) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourcesRoot,
                                                                      includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return try lines(of: url)
        }
        XCTFail("\(name) not found")
        return []
    }

    // MARK: - Conversation-store writes

    /// The tokens that mean "this write is decided by the persistence helper".
    private static let persistenceConsults = ["persistsConversation", "turnPersists"]
    /// How far above a write its check may sit: a guarded block with a little set-up in it.
    private static let consultWindow = 16

    /// The store writes that are not a turn's, each with why it may write while a private
    /// conversation is open, and how many there are — a new one in the same file still fails.
    private static let storeWriteRoster: [String: (count: Int, why: String)] = [
        // The store itself: its continue-or-start helper starting a thread.
        "ConversationStore.swift": (1, "the store's own internals"),
        // UI-test seeding, run only under the UI-test launch arguments.
        "UITestSupport.swift": (6, "UI-test fixtures, never a wearer's session"),
        // A manual selection made on the conversation page with no thread open: the wearer's act
        // on the page, not a turn. The private conversation's page (P1b) does not offer it.
        "ManualPickerView.swift": (1, "a page action, not a turn"),
        // The job chokepoint: reached only through `JobThreadPolicy`, whose persistence seam is
        // `persistsConversation`; a job and a debrief each refuse a private conversation.
        "GuidedJobFlow.swift": (1, "the job's thread, bound through the persistence seam"),
        "GuidedJobFlow+Debrief.swift": (1, "a debrief's thread; a debrief refuses private"),
    ]

    func testEveryConversationStoreWriteIsDecidedByThePersistenceHelper() throws {
        var unguarded: [String] = []
        var rostered: [String: Int] = [:]
        for url in try swiftFiles() {
            let name = url.lastPathComponent
            let source = try lines(of: url)
            for (index, line) in source.enumerated() where !Self.isComment(line) && !line.contains("func ") {
                guard ["startThread(", "appendMessage(", "continueRecentOrStartThread("]
                    .contains(where: line.contains) else { continue }
                if Self.storeWriteRoster[name] != nil {
                    rostered[name, default: 0] += 1
                    continue
                }
                let window = source[max(0, index - Self.consultWindow)...index]
                if !window.contains(where: { line in Self.persistenceConsults.contains(where: line.contains) }) {
                    unguarded.append("\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(unguarded, [],
                       "a conversation-store write a private turn could reach; check `persistsConversation` "
                           + "(or the turn's `turnPersists`) and send the turn to `notePrivateTurn` instead:\n"
                           + unguarded.joined(separator: "\n"))
        for (name, entry) in Self.storeWriteRoster {
            XCTAssertEqual(rostered[name] ?? 0, entry.count,
                           "\(name)'s store writes changed (\(entry.why)); re-justify the roster")
        }
    }

    /// The raw switch is read once, behind the helper, everywhere a turn is decided.
    func testTurnsReadTheHelperNotTheRawSwitch() throws {
        let app = try file("OpenGlassesApp.swift").filter { !Self.isComment($0) }
        let raw = app.filter { $0.contains("Config.conversationPersistenceEnabled") }
        XCTAssertEqual(raw.count, 1, "only the job flow's seam fallback reads it:\n" + raw.joined(separator: "\n"))
        let intent = try file("AskPersonaIntent.swift").filter { !Self.isComment($0) }
        XCTAssertFalse(intent.contains { $0.contains("Config.conversationPersistenceEnabled") })
        let helper = try file("AppState+PrivateConversation.swift")
        XCTAssertTrue(helper.contains { $0.contains("Config.conversationPersistenceEnabled && !privateConversation.isActive") })
    }

    // MARK: - Writers that consult the gate themselves

    /// (file, the start of the writer's declaration, a token its body must contain). Each body runs
    /// from the declaration to the next declaration at the same indentation.
    private static let selfConsultingWriters: [(file: String, declaration: String, token: String)] = [
        ("SemanticMemoryStore.swift", "func parseAndExecuteCommands(", "PrivateConversationGate.skips(.rememberTag)"),
        ("SemanticMemoryStore.swift", "func parseAndExecuteCommands(", "PrivateConversationGate.skips(.rememberGlobalTag)"),
        ("SemanticMemoryStore.swift", "func parseAndExecuteCommands(", "PrivateConversationGate.skips(.diaryTag)"),
        ("SemanticMemoryStore.swift", "func incrementTurnAndCheckNudge(", "PrivateConversationGate.skips(.memoryNudge)"),
        ("SemanticMemoryStore.swift", "private func pushToGateway(", "PrivateConversationGate.skips(.gatewayMemoryPush)"),
        ("SemanticMemoryStore.swift", "func syncFromGateway(", "PrivateConversationGate.skips(.gatewayMemoryQuery)"),
        ("MemoryLoopService.swift", "func observeTurn(", "PrivateConversationGate.skips(.memoryLoopObserveTurn)"),
        ("MemoryLoopService.swift", "func enrich(turn:", "PrivateConversationGate.skips(.memoryLoopEnrich)"),
        ("SkillEvolutionService.swift", "func noteUserTurn(message:", "PrivateConversationGate.skips(.skillEvolutionNoteUserTurn)"),
        ("TurnTrace.swift", "func append(_ trace: TurnTrace)", "PrivateConversationGate.skips(.turnTraceText)"),
        ("ActivityStore.swift", "func append(_ entry: ActivityEntry)", "PrivateConversationGate.keepsTitleOnly(.activityTrail)"),
        ("CameraService.swift", "func capturePhoto(allowPhoneFallback", "PrivateConversationGate.skips(.photoTurnToLibrary)"),
        ("LiveActivityManager.swift", "func update(", "PrivateConversationGate.placeholder(for: .liveActivitySnippet)"),
        ("WatchConnectivityManager.swift", "private func statusContext(", "PrivateConversationGate.placeholder(for: .watchLastResponse)"),
        ("HermesAgentAPIClient.swift", "func ask(", "PrivateConversationGate.skips(.hermesResponseStore)"),
        ("TranscriptionService.swift", "private func chooseEngine(", "PrivateRecognitionPolicy.allowsCloudVendor"),
        ("TranscriptionService.swift", "private func setupAndStartRecording(", "PrivateConversationGate.skips(.serverSpeechRecognition)"),
        ("NativeToolRouter.swift", "private func authorizeAndDispatch(", "privateConversationRefusal(call"),
        ("LLMService.swift", "private static func buildSystemPrompt(", "SystemPromptBuilder.privateConversationLine"),
    ]

    private func body(of declaration: String, in source: [String]) -> [String]? {
        guard let start = source.firstIndex(where: { $0.contains(declaration) && $0.contains("func ") }) else {
            return nil
        }
        let indent = source[start].prefix { $0 == " " }.count
        var end = start + 1
        while end < source.count {
            let line = source[end]
            let leading = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if leading <= indent, !trimmed.isEmpty, trimmed != "}", !trimmed.hasPrefix("//"),
               trimmed.hasPrefix("func ") || trimmed.contains(" func ") || trimmed.hasPrefix("@") {
                break
            }
            end += 1
        }
        return Array(source[start..<end])
    }

    func testEveryWriterThatConsultsTheGateItselfStillDoes() throws {
        var missing: [String] = []
        for writer in Self.selfConsultingWriters {
            guard let body = body(of: writer.declaration, in: try file(writer.file)) else {
                missing.append("\(writer.file): no `\(writer.declaration)` — the roster is stale")
                continue
            }
            if !body.contains(where: { $0.contains(writer.token) && !Self.isComment($0) }) {
                missing.append("\(writer.file) `\(writer.declaration)` no longer consults `\(writer.token)`")
            }
        }
        XCTAssertEqual(missing, [], missing.joined(separator: "\n"))
    }

    /// The Photos sink has one caller, the capture that consults the gate.
    func testThePhotosSinkIsCalledOnlyBehindTheGate() throws {
        let callers = try hits(of: "captureLibrarySink(")
        XCTAssertEqual(callers.map(\.file), ["CameraService.swift"], callers.map(\.description).joined(separator: "\n"))
    }

    /// The gateway hears the private conversation under its own key: every request that names a
    /// session names the effective one.
    func testEveryGatewayRequestUsesTheEffectiveSessionKey() throws {
        let bridge = try file("OpenClawBridge.swift").filter { !Self.isComment($0) }
        let named = bridge.filter { $0.contains("sessionKey:") || $0.contains("key: ") }
            .filter { $0.contains("GatewayRequestCatalog") || $0.contains("key: sessionKey") || $0.contains("key: effectiveSessionKey") }
        XCTAssertFalse(named.isEmpty)
        for line in named {
            XCTAssertFalse(line.contains("sessionKey: sessionKey") || line.contains("key: sessionKey"),
                           "a gateway request bypasses the private key: \(line)")
        }
    }

    // MARK: - Who may start, end and flag one

    func testOnlyTheControllerWritesTheGate() throws {
        let writers = try hits(of: "PrivateConversationGate.setActive(")
        XCTAssertEqual(Set(writers.map(\.file)), ["PrivateConversationController.swift"],
                       writers.map(\.description).joined(separator: "\n"))
    }

    func testOnlyAppStateStartsAndEndsAPrivateConversation() throws {
        var outside: [String] = []
        for pattern in ["privateConversation.begin(", "privateConversation.end(", "privateConversation.handle("] {
            for hit in try hits(of: pattern) where hit.file != "AppState+PrivateConversation.swift" {
                outside.append(hit.description)
            }
        }
        XCTAssertEqual(outside, [], "start and end through `beginPrivate` / `endPrivate` / `notePrivateEvent`:\n"
                           + outside.joined(separator: "\n"))
    }
}
