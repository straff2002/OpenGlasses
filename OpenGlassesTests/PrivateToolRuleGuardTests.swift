import XCTest
@testable import OpenGlasses

/// Plan LU P0 §4 — every native `write` tool says whether a private conversation may run it, and
/// forgetting is never blocked.
///
/// Two populations are checked, so a new write tool fails here until it is classified wherever it
/// is registered:
/// - the live registry, built as wide as it can be built headlessly (the same fixture the
///   execution-semantics gate uses), classified exactly as the router classifies a call;
/// - every tool type `ToolEffectClassification.swift` gives a writing row, read from the source, so
///   a tool registered only by `AppState` (`my_memory`), or only with a service the headless
///   registry can't build (`meeting_summary`), is covered too.
@MainActor
final class PrivateToolRuleGuardTests: XCTestCase {

    // MARK: - Every write tool is classified

    func testEveryRegisteredWriteToolIsClassified() throws {
        let names = try registeredWriteToolNames()
        let unclassified = names.filter { PrivateToolRule.kind(of: $0) == nil }.sorted()
        XCTAssertEqual(unclassified, [],
                       "these native write tools have no PrivateToolRule kind; add each to "
                           + "PrivateToolRule.kinds as .memoryLike or .wearerDirected")
        XCTAssertGreaterThan(names.count, 50, "the fixture registry must actually be wide")
    }

    func testEveryWritingRowInTheClassificationFileIsClassified() throws {
        let names = try writeToolNamesFromClassificationSource()
        let unclassified = names.filter { PrivateToolRule.kind(of: $0) == nil }.sorted()
        XCTAssertEqual(unclassified, [],
                       "these tools have a writing row in ToolEffectClassification.swift but no "
                           + "PrivateToolRule kind")
        XCTAssertGreaterThan(names.count, 60, "the scrape must actually find the writing rows")
    }

    /// The table names no tool that isn't a native write tool, so a rename or a typo can't leave a
    /// tool unclassified under its real name while its old name sits here.
    func testTheTableNamesOnlyRealWriteTools() throws {
        let known = try Set(registeredWriteToolNames()).union(writeToolNamesFromClassificationSource())
        let stale = Set(PrivateToolRule.kinds.keys).subtracting(known).sorted()
        XCTAssertEqual(stale, [], "PrivateToolRule.kinds names tools that are not native write tools")
    }

    /// The tools §4 names as memory-like are memory-like.
    func testThePlansMemoryLikeToolsAreMemoryLike() {
        for name in ["remember_scene", "my_memory", "agent_diary", "brain", "social_context",
                     "object_memory", "meeting_summary", "team_learning", "voice_skills",
                     "edit_agent_docs"] {
            XCTAssertEqual(PrivateToolRule.kind(of: name), .memoryLike, name)
        }
    }

    /// The tools §4 names as wearer-directed run as usual (decision 2).
    func testThePlansWearerDirectedToolsRun() {
        for name in ["reminder", "calendar", "save_note", "set_timer", "goals", "task", "geofence",
                     "save_location", "parking"] {
            XCTAssertEqual(PrivateToolRule.kind(of: name), .wearerDirected, name)
            XCTAssertEqual(PrivateToolRule.decision(tool: name, args: ["action": "add"]), .run, name)
        }
    }

    // MARK: - Forgetting is never blocked

    func testEveryForgetActionRuns() {
        for (tool, actions) in PrivateToolRule.forgetActions {
            for action in actions {
                XCTAssertEqual(PrivateToolRule.decision(tool: tool, args: ["action": action]), .run,
                               "\(tool) \(action)")
                XCTAssertEqual(PrivateToolRule.decision(tool: tool, args: ["action": " \(action.uppercased()) "]),
                               .run, "\(tool) \(action), as a model might spell it")
            }
        }
        XCTAssertEqual(PrivateToolRule.decision(tool: "my_memory", args: ["action": "forget"]), .run)
        XCTAssertEqual(PrivateToolRule.decision(tool: "brain", args: ["action": "forget"]), .run)
    }

    /// Every alias a memory-like tool's own switch accepts for forgetting is in the table, so a new
    /// alias can't be refused by omission.
    func testEveryForgetAliasInTheToolsOwnSwitchIsListed() throws {
        let files = [
            "my_memory": "MyMemoryTool.swift", "brain": "BrainTool.swift",
            "social_context": "SocialContextTool.swift", "object_memory": "ObjectMemoryTool.swift",
            "voice_skills": "VoiceSkillsTool.swift", "team_learning": "TeamLearningTool.swift",
            "agent_diary": "AgentDiaryTool.swift", "edit_agent_docs": "AgentDocumentTool.swift",
        ]
        let forgetWords = ["forget", "delete", "remove", "clear", "withdraw", "retract", "erase"]
        var missing: [String] = []
        for (tool, file) in files {
            let source = try sourceText("OpenGlasses/Sources/Services/NativeTools/\(file)")
            for line in source.split(separator: "\n").map(String.init)
            where line.trimmingCharacters(in: .whitespaces).hasPrefix("case \"") {
                let aliases = stringLiterals(in: line)
                guard aliases.contains(where: { alias in forgetWords.contains(where: alias.contains) }) else { continue }
                for alias in aliases where !(PrivateToolRule.forgetActions[tool] ?? []).contains(alias) {
                    missing.append("\(tool) \(alias)")
                }
            }
        }
        XCTAssertEqual(missing.sorted(), [], "forget aliases a private conversation would refuse")
    }

    // MARK: - Memory-like writes are refused, per action

    func testMemoryLikeWritesAreRefused() {
        let refused: [(String, [String: Any])] = [
            ("remember_scene", [:]),
            ("remember_scene", ["note": "the label"]),
            ("scan_badge", [:]),
            ("my_memory", ["action": "correct"]),
            ("brain", ["action": "link"]),
            ("brain", ["action": "relate"]),
            ("brain", ["action": "log_encounter"]),
            ("brain", ["action": "met_with"]),
            ("brain", ["action": "save_need"]),
            ("brain", ["action": "follow_up"]),
            ("social_context", ["action": "add"]),
            ("social_context", ["action": "remember"]),
            ("object_memory", ["action": "save"]),
            ("object_memory", ["action": "put"]),
            ("voice_skills", ["action": "save"]),
            ("voice_skills", ["action": "teach"]),
            ("team_learning", ["action": "note"]),
            ("team_learning", ["action": "amend"]),
            ("team_learning", [:]),
            ("agent_diary", ["action": "write"]),
            ("edit_agent_docs", ["action": "append"]),
            ("edit_agent_docs", ["action": "replace_section"]),
            ("edit_agent_docs", [:]),
            ("meeting_summary", [:]),
            ("meeting_summary", ["save": true]),
            // An action the table doesn't know is refused, not run.
            ("brain", ["action": "invent_a_new_write"]),
        ]
        for (tool, args) in refused {
            XCTAssertEqual(PrivateToolRule.decision(tool: tool, args: args),
                           .refuse(reason: PrivateToolRule.refusalReason), "\(tool) \(args)")
        }
    }

    func testMemoryLikeReadsRun() {
        let runs: [(String, [String: Any])] = [
            ("my_memory", [:]),
            ("my_memory", ["action": "list"]),
            ("my_memory", ["action": "about"]),
            ("brain", [:]),
            ("brain", ["action": "recall"]),
            // "remember" is the brain's recall alias, a read.
            ("brain", ["action": "remember"]),
            ("brain", ["action": "person"]),
            ("brain", ["action": "needs"]),
            ("social_context", ["action": "recall"]),
            ("object_memory", ["action": "where"]),
            ("voice_skills", ["action": "list"]),
            ("team_learning", ["action": "list"]),
            ("agent_diary", [:]),
            ("agent_diary", ["action": "search"]),
            ("edit_agent_docs", ["action": "read"]),
            ("meeting_summary", ["save": false]),
        ]
        for (tool, args) in runs {
            XCTAssertEqual(PrivateToolRule.decision(tool: tool, args: args), .run, "\(tool) \(args)")
        }
    }

    func testUnclassifiedToolsRun() {
        // Reads, messaging tools and external tools are outside this table; they run under their
        // own rules.
        XCTAssertEqual(PrivateToolRule.decision(tool: "get_weather", args: [:]), .run)
        XCTAssertEqual(PrivateToolRule.decision(tool: "send_message", args: [:]), .run)
        XCTAssertEqual(PrivateToolRule.decision(tool: "mcp__server__remember", args: [:]), .run)
    }

    func testTheRefusalReasonOffersAReminderOrANote() {
        XCTAssertTrue(PrivateToolRule.refusalReason.contains("private"))
        XCTAssertTrue(PrivateToolRule.refusalReason.contains("reminder"))
        XCTAssertTrue(PrivateToolRule.refusalReason.contains("note"))
    }

    // MARK: - Populations

    /// Native tools the router would classify `write`, from the widest headless registry.
    private func registeredWriteToolNames() throws -> [String] {
        let savedFieldAssist = Config.fieldAssistEnabled
        let savedAccessibility = Config.accessibilityModeEnabled
        let savedEntitlement = EntitlementTestScope.grant()
        Config.setFieldAssistEnabled(true)
        Config.setAccessibilityModeEnabled(true)
        defer {
            Config.setFieldAssistEnabled(savedFieldAssist)
            Config.setAccessibilityModeEnabled(savedAccessibility)
            EntitlementTestScope.restore(savedEntitlement)
        }
        let memoryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateToolRuleGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: memoryDirectory) }

        let registry = NativeToolRegistry(
            locationService: LocationService(),
            conversationStore: ConversationStore(),
            cameraService: CameraService(),
            medicalExportService: MedicalExportService(),
            semanticMemory: SemanticMemoryStore(directory: memoryDirectory))
        registry.register(MemorySearchTool())
        registry.register(AgentDiaryTool())
        registry.register(DocumentRAGTool())
        registry.register(StudyTool())
        registry.register(OpenClawSkillsTool())
        registry.register(MyMemoryTool())

        return registry.allTools.compactMap { tool -> String? in
            guard !(tool is SkillPackToolWrapper), !(tool is CustomToolWrapper) else { return nil }
            let effect = ToolEffectClassifier.nativeClass(name: tool.name, args: [:],
                                                          semantics: tool.executionSemantics)
            return effect == .write ? tool.name : nil
        }
    }

    /// Tool names whose row in `ToolEffectClassification.swift` writes (`.local`, `.external` or
    /// `.actuation`), less the classes that are never `write` (messaging, disclosure, money, and
    /// tools whose effect this app cannot say).
    private func writeToolNamesFromClassificationSource() throws -> [String] {
        let table = try sourceText("OpenGlasses/Sources/Services/NativeTools/ToolEffectClassification.swift")
        var writingTypes: [String] = []
        var currentType: String?
        for line in table.split(separator: "\n").map(String.init) {
            if let type = firstCapture(#"^extension\s+([A-Za-z0-9_]+)"#, in: line) { currentType = type }
            if let type = currentType,
               line.range(of: #"\.(local|external|actuation)\("#, options: .regularExpression) != nil,
               !writingTypes.contains(type) {
                writingTypes.append(type)
            }
        }

        let declarations = try typeDeclarations()
        let neverWrite = ToolEffectClassifier.messagingTools
            .union(ToolEffectClassifier.sensitiveDisclosureTools)
            .union(ToolEffectClassifier.financialTools)
            .union(ToolEffectClassifier.arbitraryCapabilityTools)
        var names: [String] = []
        var unresolved: [String] = []
        for type in writingTypes {
            guard let name = declarations[type].flatMap(toolName(after:)) else {
                unresolved.append(type)
                continue
            }
            if !neverWrite.contains(name) { names.append(name) }
        }
        XCTAssertEqual(unresolved, [], "couldn't find the tool name these types declare")
        return names
    }

    /// The `name` a tool type declares: the first `let name = "…"` (or `var name: String { "…" }`)
    /// after the type's declaration.
    private func toolName(after declaration: Substring) -> String? {
        firstCapture(#"(?:let|var)\s+name(?:\s*:\s*String)?\s*(?:=|\{)\s*"([a-z_]+)""#, in: String(declaration))
    }

    /// Every `struct`/`class` declared under `OpenGlasses/Sources`, mapped to the source text from its
    /// declaration on. Built once: one pass per file rather than one per type.
    private func typeDeclarations() throws -> [String: Substring] {
        if let cached = Self.cachedDeclarations { return cached }
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:struct|class)\s+([A-Za-z0-9_]+)"#) else { return [:] }
        var declarations: [String: Substring] = [:]
        for path in try allSourceFiles() {
            let source = try sourceText(path)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let nameRange = Range(match.range(at: 1), in: source),
                      let whole = Range(match.range, in: source) else { continue }
                let type = String(source[nameRange])
                if declarations[type] == nil { declarations[type] = source[whole.upperBound...] }
            }
        }
        Self.cachedDeclarations = declarations
        return declarations
    }

    private static var cachedDeclarations: [String: Substring]?

    // MARK: - Source helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func allSourceFiles() throws -> [String] {
        try FileManager.default
            .subpathsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("OpenGlasses/Sources").path)
            .filter { $0.hasSuffix(".swift") }
            .map { "OpenGlasses/Sources/\($0)" }
            .sorted()
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func stringLiterals(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]*)""#) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
            Range($0.range(at: 1), in: line).map { String(line[$0]) }
        }
    }
}
