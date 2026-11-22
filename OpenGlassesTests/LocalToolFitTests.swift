import XCTest
@testable import OpenGlasses

/// Plan MQ P3 (found on the phone, 2026-11-22): a native tool turn's definitions are fitted to the
/// prompt budget before the history is trimmed, compact definitions first, then dropping from the
/// lowest-priority end, then none; and a native tool turn on Gemma 4 E2B may run on a larger window
/// on a phone with the room.
final class LocalToolFitTests: XCTestCase {

    // MARK: - The fit's order

    private final class Log { var calls: [String] = [] }

    /// A fake tokenizer: a fixed prompt, then each tool's cost at its detail.
    private func counter(base: Int, standard: [Int], compact: [Int],
                         log: Log? = nil) -> (Int, LocalToolFit.Detail) -> Int {
        { kept, detail in
            log?.calls.append("\(kept)\(detail == .compact ? "c" : "s")")
            let costs = detail == .compact ? compact : standard
            return base + costs.prefix(kept).reduce(0, +)
        }
    }

    func testEveryToolAtFullDetailWhenItFits() {
        let choice = LocalToolFit.choose(offered: 3, budget: 2_000,
                                         tokenCount: counter(base: 1_000, standard: [300, 300, 300], compact: [100, 100, 100]))
        XCTAssertEqual(choice, .init(kept: 3, detail: .standard, tokens: 1_900))
    }

    func testCompactBeforeAnyToolIsDropped() {
        let log = Log()
        let choice = LocalToolFit.choose(offered: 3, budget: 1_400,
                                         tokenCount: counter(base: 1_000, standard: [300, 300, 300],
                                                             compact: [100, 100, 100], log: log))
        XCTAssertEqual(choice, .init(kept: 3, detail: .compact, tokens: 1_300))
        XCTAssertEqual(log.calls, ["3s", "3c"], "standard first, then the same tools compact")
    }

    func testThenTheLowestPriorityToolsGoFirst() {
        let log = Log()
        let choice = LocalToolFit.choose(offered: 4, budget: 1_250,
                                         tokenCount: counter(base: 1_000, standard: [400, 400, 400, 400],
                                                             compact: [100, 100, 100, 100], log: log))
        XCTAssertEqual(choice, .init(kept: 2, detail: .compact, tokens: 1_200),
                       "the first two in priority order are kept; the last two went")
        XCTAssertEqual(log.calls, ["4s", "4c", "3c", "2c"])
    }

    func testThenNoToolsAtAll() {
        let choice = LocalToolFit.choose(offered: 2, budget: 1_050,
                                         tokenCount: counter(base: 1_000, standard: [400, 400], compact: [100, 100]))
        XCTAssertEqual(choice, .init(kept: 0, detail: .standard, tokens: nil), "an answer without tools")
        let none = LocalToolFit.choose(offered: 0, budget: 10) { _, _ in XCTFail("nothing to measure"); return 0 }
        XCTAssertEqual(none.kept, 0)
    }

    func testFullDetailMustLeaveTheHistoryReserve() {
        let count = counter(base: 1_000, standard: [300, 300, 300], compact: [100, 100, 100])
        XCTAssertEqual(LocalToolFit.choose(offered: 3, budget: 2_000, tokenCount: count).detail, .standard)
        let withHistory = LocalToolFit.choose(offered: 3, budget: 2_000, reserve: 600, tokenCount: count)
        XCTAssertEqual(withHistory, .init(kept: 3, detail: .compact, tokens: 1_300),
                       "1,900 would leave 100 for the conversation; compact leaves 700")
        XCTAssertEqual(LocalToolFit.choose(offered: 3, budget: 2_500, reserve: 600, tokenCount: count).detail, .standard)
    }

    func testTheChoiceIsNeverOverBudget() {
        for budget in stride(from: 900, through: 2_400, by: 37) {
            let count = counter(base: 1_000, standard: [500, 300, 200, 100], compact: [200, 120, 80, 40])
            let choice = LocalToolFit.choose(offered: 4, budget: budget, tokenCount: count)
            if choice.kept > 0 {
                XCTAssertLessThanOrEqual(count(choice.kept, choice.detail), budget, "budget \(budget)")
                XCTAssertEqual(choice.tokens, count(choice.kept, choice.detail))
            }
            // Nothing smaller was passed over: one more tool, or full detail, would not have fitted.
            if choice.kept < 4 { XCTAssertGreaterThan(count(choice.kept + 1, .compact), budget) }
            if choice.detail == .compact { XCTAssertGreaterThan(count(4, .standard), budget) }
        }
    }

    // MARK: - At the runtime: tools first, then history

    private func spec(_ name: String, words: Int) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": String(repeating: "word ", count: words),
                      "parameters": ["type": "object", "properties": [:]] as [String: Any]] as [String: Any]]
    }

    /// The runtime's fit (`LocalLLMService.fitTools`) runs with no history, and the history is then
    /// trimmed into what the kept tools leave; a tool turn whose definitions overflow does not throw.
    func testTheToolsAreFittedWithNoHistoryAndOnlyThenTheHistoryIsTrimmed() throws {
        let names = ["field_session", "reading", "table_lookup"]
        let turn = LocalToolTurn(
            history: (0..<6).map { .user("earlier \($0)") }, turn: [.user("log 3.5 in. w.c.")],
            tools: names.map { spec($0, words: 300) }, compactTools: names.map { spec($0, words: 60) },
            thinkingOff: true, fallbackInstructions: "", contextWindow: 4_096)
        // Prompt 2,000; a standard tool ~300, a compact one ~60; each earlier message 200.
        func tokens(history: Int, tools: [[String: Any]]) -> Int {
            2_000 + history * 200 + tools.reduce(0) {
                $0 + (((($1["function"] as? [String: Any])?["description"] as? String)?.count ?? 0) / 5)
            }
        }
        var measuredHistory: [Int] = []
        let fitted = LocalLLMService.fitTools(turn, rendersTools: true, budget: 2_600, window: 4_096) { kept, detail in
            measuredHistory.append(0)
            return tokens(history: 0, tools: turn.specs(kept: kept, detail: detail))
        }
        XCTAssertEqual(measuredHistory.count, 2, "standard, then compact")
        XCTAssertEqual(fitted.report, .init(offered: 3, keptNames: names, compact: true, contextWindow: 4_096))
        XCTAssertEqual(fitted.turn.tools.count, 3)
        let history = try LocalModelBudget.historyFittingBudget(
            history: turn.history.map { (role: $0.role.rawValue, content: $0.content) }, budget: 2_600
        ) { tokens(history: $0.count, tools: fitted.turn.tools) }
        XCTAssertEqual(history.count, 2, "the history takes what the compact tools leave: 2,000 + 180 + 2 × 200")
        XCTAssertEqual(history.map(\.content), ["earlier 4", "earlier 5"], "oldest first")

        // Definitions that can never fit leave a turn without tools, and it still runs.
        let tight = LocalLLMService.fitTools(turn, rendersTools: true, budget: 2_050, window: 4_096) { kept, detail in
            tokens(history: 0, tools: turn.specs(kept: kept, detail: detail))
        }
        XCTAssertEqual(tight.report.kept, 0)
        XCTAssertTrue(tight.turn.tools.isEmpty)
        XCTAssertFalse(tight.report.compact)
        XCTAssertNoThrow(try LocalModelBudget.historyFittingBudget(history: [], budget: 2_050) { _ in 2_000 })
        // Only the system prompt and the turn alone overflowing throws, as before.
        XCTAssertThrowsError(try LocalModelBudget.historyFittingBudget(history: [], budget: 1_900) { _ in 2_000 })
    }

    func testATurnWhoseTemplateRendersNoToolsIsNotFitted() {
        let turn = LocalToolTurn(history: [], turn: [.user("hi")], tools: [spec("reading", words: 300)],
                                 thinkingOff: true, fallbackInstructions: "Output exactly …")
        let fitted = LocalLLMService.fitTools(turn, rendersTools: false, budget: 10, window: 4_096) { _, _ in
            XCTFail("the Hermes instruction stands in; no definitions to measure"); return 0
        }
        XCTAssertEqual(fitted.report.keptNames, ["reading"])
        XCTAssertEqual(fitted.turn.tools.count, 1)
    }

    // MARK: - The dispatcher

    func testACallToADroppedToolIsNotDispatchable() {
        let report = LocalToolFit.Report(offered: 3, keptNames: ["field_session", "reading"], compact: true,
                                         contextWindow: 4_096)
        let offered = ["field_session", "reading", "table_lookup"]
        XCTAssertEqual(LocalToolFit.dispatchable(offered: offered, report: report), ["field_session", "reading"])
        XCTAssertEqual(LocalToolFit.dispatchable(offered: offered, report: nil), Set(offered),
                       "a runtime that fitted nothing leaves the offer as it was")
        XCTAssertEqual(report.dropped, 1)
        XCTAssertTrue(LocalToolLoop.unofferedToolMessage(name: "table_lookup",
                                                         offered: LocalToolFit.dispatchable(offered: offered, report: report))
            .hasPrefix("Error: the tool 'table_lookup' is not available on this turn."))
    }

    // MARK: - Compact definitions

    @MainActor
    func testCompactDefinitionsKeepEveryTypeAndTheirDepthAndAreSmaller() throws {
        // The Field Assist tools register only with Field Assist on and entitled.
        let previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let previousEntitlement = EntitlementTestScope.grant()
        defer {
            if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
            EntitlementTestScope.restore(previousEntitlement)
        }
        let registry = NativeToolRegistry(locationService: LocationService())
        for name in FieldAssistLocalToolSet.priority {
            let tool = try XCTUnwrap(registry.tool(named: name), name)
            let standard = OnDeviceToolSchema.localToolSpec(name: name, description: tool.description,
                                                            parameters: tool.parametersSchema)
            let compact = OnDeviceToolSchema.localToolSpec(name: name, description: tool.description,
                                                           parameters: tool.parametersSchema, limits: .compact)
            let parameters = try XCTUnwrap((compact["function"] as? [String: Any])?["parameters"] as? [String: Any])
            func check(_ node: [String: Any], depth: Int, path: String) {
                XCTAssertNotNil(node["type"] as? String, "\(name): \(path) keeps its type")
                XCTAssertLessThanOrEqual(depth, OnDeviceToolSchema.localMaxDepth + 1, "\(name): \(path)")
                if let properties = node["properties"] as? [String: Any] {
                    XCTAssertLessThanOrEqual(depth, OnDeviceToolSchema.localMaxDepth, "\(name): \(path) nests at most twice")
                    for (key, child) in properties { check(child as! [String: Any], depth: depth + 1, path: path + "." + key) }
                }
                if let items = node["items"] as? [String: Any] { check(items, depth: depth + 1, path: path + "[]") }
            }
            check(parameters, depth: 1, path: name)
            // The same properties, the same types and choices, the same required list.
            let standardParameters = try XCTUnwrap((standard["function"] as? [String: Any])?["parameters"] as? [String: Any])
            XCTAssertEqual(Set((parameters["properties"] as? [String: Any] ?? [:]).keys),
                           Set((standardParameters["properties"] as? [String: Any] ?? [:]).keys), name)
            XCTAssertEqual(parameters["required"] as? [String], standardParameters["required"] as? [String], name)
            XCTAssertEqual(OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema, limits: .compact)
                            .strippingDescriptions,
                           OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema).strippingDescriptions,
                           "\(name): coercion reads the same tree")
            let required = Set(parameters["required"] as? [String] ?? [])
            for (key, child) in parameters["properties"] as? [String: Any] ?? [:] where !required.contains(key) {
                // Dropped, or only what is not a description: its choices, the JSON-as-text note, or a
                // nested object's own short line.
                let description = (child as? [String: Any])?["description"] as? String
                XCTAssertTrue(description == nil || description!.hasPrefix("One of:")
                              || description!.contains("JSON value written as text")
                              || description!.count <= OnDeviceToolSchema.Limits.compact.propertyDescription + 1,
                              "\(name).\(key): an optional property's description is dropped")
            }
            let description = try XCTUnwrap((compact["function"] as? [String: Any])?["description"] as? String)
            XCTAssertLessThanOrEqual(description.count, OnDeviceToolSchema.Limits.compact.toolDescription + 1)
            XCTAssertLessThan(OnDeviceToolSchema.localEstimatedTokens(spec: compact),
                              OnDeviceToolSchema.localEstimatedTokens(spec: standard), name)
        }
        XCTAssertEqual(OnDeviceToolSchema.Limits.standard.optionalPropertyDescription, nil,
                       "the Apple path's limits are unchanged")
    }

    // MARK: - The tool turn's window

    private func readings(ramGB: Double, killLimitGB: Double?, footprintGB: Double = 3.0) -> LocalMemoryBudget.Readings {
        let gb = 1_024.0 * 1_024 * 1_024
        guard let killLimitGB else {
            return .init(availableBytes: 0, footprintBytes: Int64(footprintGB * gb), recommendedWorkingSetBytes: 0,
                         marketingRAMGB: ramGB)
        }
        return .init(availableBytes: Int64((killLimitGB - footprintGB) * gb), footprintBytes: Int64(footprintGB * gb),
                     recommendedWorkingSetBytes: 0, marketingRAMGB: ramGB)
    }

    private static let gemma = "mlx-community/gemma-4-e2b-it-4bit"

    func testGemmaGetsTheLargerWindowOnABigPhoneForNativeToolTurnsOnly() {
        let roomy = readings(ramGB: 12, killLimitGB: 6.44)
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 12, readings: roomy),
                       .init(tokens: 6_144, reason: .raised))
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 8, readings: readings(ramGB: 8, killLimitGB: 5.4)),
                       .init(tokens: 6_144, reason: .raised), "8 GB is enough")
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 6, readings: readings(ramGB: 6, killLimitGB: 4)),
                       .init(tokens: 4_096, reason: .smallPhone), "a 6 GB phone stays at 4,096")
        XCTAssertEqual(LocalModelBudget.promptBudget(for: Self.gemma, contextWindow: 6_144), 5_504)
        XCTAssertEqual(LocalModelBudget.toolDefinitionBudget(for: Self.gemma, contextWindow: 6_144), 1_376)
    }

    func testFlagOffOtherModelsAndOtherTurnsAreUnchanged() {
        let roomy = readings(ramGB: 12, killLimitGB: 6.44)
        // Flag off (or a model off the allowlist, or GGUF): `usesNativeToolCalls` is false.
        for (model, runtime, flag) in [(Self.gemma, LocalModelRuntime.mlx, false),
                                       ("mlx-community/gemma-4-e4b-it-4bit", .mlx, true),
                                       (Self.gemma, .llamaCpp, true)] {
            let native = LocalNativeToolPolicy.usesNativeToolCalls(modelID: model, runtime: runtime, flagOn: flag)
            XCTAssertFalse(native)
            XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: model, nativeToolCalls: native,
                                                                  marketingRAMGB: 12, readings: roomy),
                           .init(tokens: LocalModelBudget.contextWindow(for: model), reason: .ordinary))
        }
        // A model that is not allowlisted gets nothing even if a caller says the turn is native.
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                                                              nativeToolCalls: true, marketingRAMGB: 12, readings: roomy).tokens,
                       4_096)
        // The ordinary windows and budgets are what they were.
        XCTAssertEqual(LocalModelBudget.contextWindow(for: Self.gemma), 4_096)
        XCTAssertEqual(LocalModelBudget.promptBudget(for: Self.gemma), 3_456)
        XCTAssertEqual(LocalModelBudget.toolDefinitionBudget(for: Self.gemma), 864)
        XCTAssertEqual(LocalModelBudget.promptBudget(for: Self.gemma, contextWindow: 4_096), 3_456)
    }

    func testTheRaiseKeepsThePlansReserveUnderTheKillLimit() {
        let gb = 1_024.0 * 1_024 * 1_024
        let shape = LocalModelBudget.kvCacheShapes[Self.gemma]!
        let kv = shape.conservativeBytes(tokens: 6_144)
        // Exactly at the edge: footprint + working set + cache + reserve == kill limit.
        let footprint = Int64(3.0 * gb)
        let edge = footprint + MemoryHeadroom.workingOverheadBytes + kv + LocalModelBudget.admissionComfortMarginBytes
        let fits = LocalMemoryBudget.Readings(availableBytes: edge - footprint, footprintBytes: footprint,
                                              recommendedWorkingSetBytes: 0, marketingRAMGB: 8)
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 8, readings: fits).reason, .raised)
        let short = LocalMemoryBudget.Readings(availableBytes: edge - footprint - 1, footprintBytes: footprint,
                                               recommendedWorkingSetBytes: 0, marketingRAMGB: 8)
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 8, readings: short),
                       .init(tokens: 4_096, reason: .memory))
        // Before a load the weights are charged too.
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true,
                                                              marketingRAMGB: 8, readings: fits,
                                                              residentWeightsBytes: 1).reason, .memory)
        // No per-process limit to read (simulator, Mac): not judged, as LocalMemoryBudget never judges it.
        XCTAssertEqual(LocalModelBudget.toolTurnContextWindow(modelId: Self.gemma, nativeToolCalls: true, marketingRAMGB: 16,
                                                              readings: readings(ramGB: 16, killLimitGB: nil)).reason, .raised)
    }

    func testGemma4E2BsCacheFromItsConfig() {
        let shape = LocalModelBudget.kvCacheShapes[Self.gemma]!
        // 3 full-attention layers × K and V × 1 head × 512 × 2 bytes a token; 12 sliding layers held
        // at their 512-token window plus one 512-token prefill chunk.
        let fullPerToken: Int64 = 3 * 2 * 512 * 2            // 6,144
        let slidingPerToken: Int64 = 12 * 2 * 256 * 2        // 12,288
        XCTAssertEqual(shape.bytes(tokens: 1), fullPerToken + slidingPerToken)
        let atRaised: Int64 = fullPerToken * 6_144 + slidingPerToken * 1_024
        XCTAssertEqual(shape.bytes(tokens: 6_144), atRaised)
        let mebibyte: Int64 = 1_024 * 1_024
        XCTAssertEqual(shape.bytes(tokens: 6_144) / mebibyte, 48, "about 48 MB at the raised window")
        let conservative: Int64 = 15 * 2 * 512 * 2 * 6_144
        XCTAssertEqual(shape.conservativeBytes(tokens: 6_144), conservative, "the gate's bound: 180 MiB")
        XCTAssertGreaterThan(shape.conservativeBytes(tokens: 6_144), shape.bytes(tokens: 6_144))
    }

    // MARK: - The order the device app uses

    func testTheDeviceAppOrdersACaseLikeTheApp() {
        let offered = ["table_lookup", "get_datetime", "field_session", "reading"]
        let field = FieldAssistLocalToolSet.ordered(offered, utterance: "log the manifold pressure reading")
        XCTAssertEqual(field, ["reading", "field_session", "table_lookup"], "the turn's words, then the priority list")
        XCTAssertEqual(LocalNativeToolPolicy.ordered(field: field, everyday: ["get_datetime"], utterance: "x"),
                       ["reading", "field_session", "table_lookup", "get_datetime"])
        // `nativeToolNames` is that order, cut to the budget.
        XCTAssertEqual(LocalNativeToolPolicy.nativeToolNames(field: field, everyday: ["get_datetime"], utterance: "x",
                                                             estimatedTokens: { _ in 10 }, budgetTokens: 1_000),
                       ["reading", "field_session", "table_lookup", "get_datetime"])
    }
}

private extension OnDeviceToolSchema.Node {
    /// The tree with every description removed: what coercion and the graders read.
    var strippingDescriptions: OnDeviceToolSchema.Node {
        switch self {
        case .string, .integer, .number, .boolean: return self
        case .array(let item): return .array(item.strippingDescriptions)
        case .object(let name, _, let properties):
            return .object(name: name, description: nil, properties: properties.map {
                .init(name: $0.name, description: nil, node: $0.node.strippingDescriptions, isOptional: $0.isOptional)
            })
        }
    }
}
