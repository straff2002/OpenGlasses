import XCTest
@testable import OpenGlasses

/// Plan NI: a support report shows what `rule_chain`, `table_lookup` and `manual_lookup` were
/// asked and what they answered, with the code books' own text (cells, notes, passages) left out
/// (owner decision D1). Run end to end on an invented vault whose one book prints Tables 99, 98,
/// 97 and 90: every table, row, rule and value is made up.
@MainActor
final class FieldToolReportTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "field_tool_report_test"
    private static let book = "Invented Book A"
    private static let utc = TimeZone(identifier: "UTC")!
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldToolReportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        TurnRecorder.reset(ledger: TurnLedger(), now: { [epoch] in epoch }, micRoutePorts: { [] })
    }

    override func tearDown() {
        TurnRecorder.reset()
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - The invented vault

    private func startSession() async throws -> (service: FieldSessionService, store: DocumentStore) {
        let dir = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(printed: "12"),
                                                       TableFixtureLayouts.twoLevelHeader(),
                                                       TableFixtureLayouts.unitsInHeader(),
                                                       TableFixtureLayouts.groupingBands()]),
                                    named: "a.pdf", in: docs)
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Field Tool Report Test", version: "1.0.0",
            files: ["safety.md", "chains.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "a.pdf", title: Self.book)],
            gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nIsolate before work.".write(to: dir.appendingPathComponent("safety.md"),
                                                     atomically: true, encoding: .utf8)
        try RuleChainFixtures.chainsMarkdown.write(to: dir.appendingPathComponent("chains.md"),
                                                   atomically: true, encoding: .utf8)

        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let report = try VaultImporter.installReporting(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: report.manifest, into: store)

        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        service.sourceCenter = ShowSourceCenter()
        service.sourceCenter.isAppActive = { true }
        service.sourceCenter.announce = { _ in }
        _ = try service.startSession(vaultId: report.manifest.id, assetId: nil)
        return (service, store)
    }

    // MARK: - Through the recorder, into a report

    /// One call as the dispatcher makes it: run inside the report collector, then noted on the turn.
    private func call(_ name: String, _ args: [String: Any],
                      _ run: () async throws -> String) async rethrows -> (result: String, entry: ToolReportText.Entry?) {
        let (result, entry) = try await ToolReportText.collect { try await run() }
        TurnRecorder.noteToolResult(name: name, outcome: "completed", query: args["query"] as? String,
                                    result: result, arguments: args, report: entry,
                                    turnID: TurnRecorder.toolTraceID, secrets: { [] })
        return (result, entry)
    }

    /// The support report for one job whose single turn made `calls`.
    private func supportReport(sessionId: String, _ calls: () async throws -> Void) async throws -> String {
        var sealed: [TurnTimeline] = []
        TurnRecorder.traceSink = { sealed.append($0) }
        TurnRecorder.beginTurn()
        try await calls()
        TurnRecorder.endTurn()
        var timeline = try XCTUnwrap(sealed.first)
        timeline.mark(.commit, at: epoch)
        timeline.fieldSessionId = sessionId
        var session = FieldSession(id: sessionId, vaultId: Self.vaultId, assetId: nil, mode: .aiOnly,
                                   startedAt: epoch.addingTimeInterval(-60), outcome: .resolved, escalations: [],
                                   billableSeconds: 0)
        session.jobReference = "1005"
        let job = JobTranscriptExport.job(session: session, vaultName: "Field Tool Report Test", thread: nil, events: [])
        return JobTranscriptExport.document(scope: .job(sessionId: sessionId), jobs: [job],
                                            exportedAt: epoch.addingTimeInterval(3_600), timeZone: Self.utc,
                                            details: .init(traces: [TurnTrace(timeline, sealedAt: epoch)])).body
    }

    /// The build-770 case: every start was refused by the start gate, and the report said
    /// `rule_chain (completed)` and nothing more. Now it shows what was asked and the refusal.
    func testARefusedChainStartShowsItsArgumentsAndTheRefusalInTheReport() async throws {
        let (service, store) = try await startSession()
        let tool = RuleChainTool(documentStore: store, sessionService: service,
                                 currentUtterance: { "what conductor do I need for this load" },
                                 previousReply: { nil })
        let args: [String: Any] = ["action": "start", "chain": "Size a conductor for a load"]
        let body = try await supportReport(sessionId: service.activeSession?.id ?? "s1") {
            let (result, _) = try await call("rule_chain", args) { try await tool.execute(args: args) }
            XCTAssertEqual(RuleChainFixtures.withoutRunningNow(result), RuleChainTool.notAskedRefusal)
        }
        XCTAssertNil(service.activeChain, "nothing started")
        XCTAssertTrue(body.contains("tools: rule_chain (completed)"), body)
        XCTAssertTrue(body.contains("rule_chain (tool call 1, completed):"), body)
        XCTAssertTrue(body.contains("arguments: action: start · chain: Size a conductor for a load"), body)
        XCTAssertTrue(body.contains(RuleChainTool.notAskedRefusal), body)
        XCTAssertFalse(body.contains("returned text, with the book's own text left out"), "a chain's text is the app's and the organisation's: shown as it is")
    }

    /// A cell found in the book: its arguments and where it was found are in the report, the
    /// cell's text is not.
    func testATableLookupShowsItsArgumentsAndWhereItFoundTheCellButNotTheCell() async throws {
        let (service, store) = try await startSession()
        let tool = TableLookupTool(documentStore: store, sessionService: service, currentUtterance: { nil })
        let args: [String: Any] = ["table": "Table 99", "row": "QXRT three conductors", "column": "Rating group 2"]
        var returned = ""
        let body = try await supportReport(sessionId: service.activeSession?.id ?? "s1") {
            let (result, entry) = try await call("table_lookup", args) { try await tool.execute(args: args) }
            returned = result
            guard case .bookTextLeftOut(_, let leftOut)? = entry else {
                return XCTFail("a found cell records a version without the book's text, got \(String(describing: entry))")
            }
            XCTAssertGreaterThanOrEqual(leftOut, "\"35\"".count)
        }
        XCTAssertTrue(returned.contains("column Rating group 2: \"35\""), "the model still gets the cell: \(returned)")
        XCTAssertTrue(body.contains("arguments: table: Table 99 · row: QXRT three conductors · column: Rating group 2"), body)
        XCTAssertTrue(body.contains("returned text, with the book's own text left out"), body)
        XCTAssertTrue(body.contains("column Rating group 2: \(TableLookup.leftOutCell)"), body)
        XCTAssertTrue(body.contains("Source:"), "where it was found stays: \(body)")
        XCTAssertFalse(body.contains("\"35\""), "the cell's text is not in the report: \(body)")
    }

    /// A lookup that gave nothing from the book is the app's words: shown in full.
    func testALookupThatAsksWhichColumnIsShownAsItIs() async throws {
        let (service, store) = try await startSession()
        let tool = TableLookupTool(documentStore: store, sessionService: service, currentUtterance: { nil })
        let args: [String: Any] = ["table": "Table 99", "row": "QXRT three conductors", "column": "Rating group 7"]
        var returned = ""
        let body = try await supportReport(sessionId: service.activeSession?.id ?? "s1") {
            let (result, entry) = try await call("table_lookup", args) { try await tool.execute(args: args) }
            returned = result
            XCTAssertEqual(entry, .asReturned)
        }
        XCTAssertFalse(returned.contains("Source:"), "no cell was given: \(returned)")
        XCTAssertTrue(body.contains(returned.components(separatedBy: .newlines)[0]), body)
        XCTAssertFalse(body.contains("returned text, with the book's own text left out"), body)
    }

    /// The personal-manuals path, or anything else that does not say what it returned, is shown by
    /// size only: the policy fails closed.
    func testALookupThatRecordedNothingIsShownBySizeOnly() async throws {
        let args: [String: Any] = ["query": "QX100 fan relay"]
        let body = try await supportReport(sessionId: "s1") {
            _ = await self.call("manual_lookup", args) { "Manual passages for 'QX100 fan relay': invented passage words" }
        }
        XCTAssertTrue(body.contains("arguments: query: QX100 fan relay"), body)
        XCTAssertTrue(body.contains("returned text: not shown ("), body)
        XCTAssertFalse(body.contains("invented passage words"), body)
    }

    // MARK: - The lookups' report versions, pure

    func testATablesNotesAreLeftOutWithItsCells() throws {
        let page = ManualTable.Page(physical: 4, printed: nil)
        let table = try XCTUnwrap(TableExtractor.extractAll(words: TableFixtureLayouts.words(TableFixtureLayouts.footnotes()),
                                                            page: page).first?.outcome.table)
        let outcome = TableLookup.resolve(.init(table: "Table 95", row: "QXRT"),
                                          in: [.init(documentId: "a", documentName: Self.book, table: table)])
        XCTAssertTrue(TableLookup.render(outcome).contains("Value for a dry location."))
        guard case .bookTextLeftOut(let text, let leftOut) = TableLookupTool.reportEntry(outcome) else {
            return XCTFail("a found cell has a report version")
        }
        XCTAssertFalse(text.contains("Value for a dry location."), text)
        XCTAssertFalse(text.contains("\"40\""), text)
        XCTAssertTrue(text.contains("Notes: 1 note \(TableLookup.leftOutCell)"), text)
        XCTAssertTrue(text.contains("row QXRT"), text)
        XCTAssertGreaterThan(leftOut, "Value for a dry location.".count)
    }

    func testAManualPassageKeepsItsCitationAndLosesItsWords() {
        let passage = VaultRetriever.Passage(documentId: "d", documentName: "Invented Manual", chunkIndex: 3,
                                             text: "Invented passage words about the QX100 relay.", page: 12,
                                             section: nil, similarity: 0.8, score: 0.8, matchedTokens: ["QX100"])
        let outcome = RetrievalOutcome.sufficient([passage])
        let full = "Read from the label: QX100\n\n" + VaultRetriever.toolResult(outcome, query: "QX100 relay")
            + "\n\nAn invented hint."
        let report = VaultRetriever.reportToolResult(outcome, query: "QX100 relay")
        XCTAssertEqual(report.leftOut, passage.markedText.count)
        guard case .bookTextLeftOut(let text, let leftOut) = ManualLookupTool.reportEntry(
            result: full, passagesBlock: VaultRetriever.toolResult(outcome, query: "QX100 relay"), report: report) else {
            return XCTFail("passages have a report version")
        }
        XCTAssertEqual(leftOut, passage.markedText.count)
        XCTAssertFalse(text.contains("Invented passage words"), text)
        XCTAssertTrue(text.contains("Source: \(passage.citation)"), text)
        XCTAssertTrue(text.contains("[passage left out of the report: \(passage.markedText.count) characters]"), text)
        XCTAssertTrue(text.hasPrefix("Read from the label: QX100"), "the lines around the passages stay")
        XCTAssertTrue(text.hasSuffix("An invented hint."), text)

        // A block that cannot be found in the result is never guessed at.
        XCTAssertEqual(ManualLookupTool.reportEntry(result: "something else", passagesBlock: "a block", report: report),
                       .sizeOnly)
    }

    // MARK: - The policy and the evidence, pure

    func testOnlyTheNamedToolsKeepEvidenceAndOnlyTheirNamedArguments() {
        XCTAssertTrue(ToolReportPolicy.keepsEvidence("rule_chain"))
        XCTAssertFalse(ToolReportPolicy.keepsEvidence("save_note"))
        let kept = ToolReportPolicy.arguments(of: "manual_lookup", in: [
            "query": "QX100\nrelay", "use_camera": true, "api_key": "never",
            "queries": [["language": "uk", "query": "реле QX100"], ["language": "ja", "query": ""]],
        ])
        XCTAssertEqual(kept.map(\.name), ["query", "use_camera", "queries"])
        XCTAssertEqual(kept.map(\.value), ["QX100 relay", "true", "uk: реле QX100"])
    }

    func testADispatcherRefusalOfALookupIsTheAppsWords() {
        XCTAssertEqual(ToolReportPolicy.returned(tool: "table_lookup", outcome: "refused", result: "Not allowed.", report: nil),
                       .asReturned("Not allowed."))
        XCTAssertEqual(ToolReportPolicy.returned(tool: "table_lookup", outcome: "completed", result: "abc", report: nil),
                       .sizeOnly(3))
        XCTAssertEqual(ToolReportPolicy.returned(tool: "rule_chain", outcome: "completed", result: "abc", report: nil),
                       .asReturned("abc"))
    }

    func testEvidenceIsMaskedBeforeItIsCutAndSharesTheTurnBudgetWithSearches() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.noteToolResult(name: "web_search", outcome: "completed", query: "q",
                                    result: String(repeating: "s", count: 20_000),
                                    turnID: TurnRecorder.toolTraceID, secrets: { [] })
        TurnRecorder.noteToolResult(name: "rule_chain", outcome: "completed", query: nil,
                                    result: "Chain stopped. invented-secret-value " + String(repeating: "r", count: 20_000),
                                    arguments: ["action": "answer", "step": "load",
                                                "value": "32 invented-secret-value " + String(repeating: "v", count: 2_000)],
                                    turnID: TurnRecorder.toolTraceID, secrets: { ["invented-secret-value"] })
        for _ in 0..<3 {
            TurnRecorder.noteToolResult(name: "rule_chain", outcome: "completed", query: nil,
                                        result: String(repeating: "r", count: 20_000), arguments: ["action": "status"],
                                        turnID: TurnRecorder.toolTraceID, secrets: { [] })
        }
        TurnRecorder.endTurn()
        let notes = sunk[0].toolCalls
        let detail = notes[1].detail
        XCTAssertNil(notes[1].search)
        XCTAssertEqual(detail?.arguments.map(\.name), ["action", "step", "value"])
        XCTAssertEqual(detail?.arguments.last?.value.count, TurnTimeline.ToolEvidence.argumentLimit)
        XCTAssertEqual(detail?.arguments.last?.truncated, true)
        XCTAssertFalse(detail?.arguments.last?.value.contains("invented-secret-value") ?? true)
        XCTAssertFalse(detail?.returned.contains("invented-secret-value") ?? true)
        XCTAssertEqual(detail?.returnedTruncated, true)
        let kept = notes.reduce(0) { $0 + ($1.search?.result.count ?? 0) + ($1.detail?.returned.count ?? 0) }
        XCTAssertEqual(kept, TurnTimeline.SearchEvidence.turnResultLimit)
        XCTAssertEqual(notes.last?.detail?.returned, "")
    }

    func testAPrivateConversationsTraceAndOtherToolsKeepNoEvidence() {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: epoch)
        timeline.toolCalls = [
            .init(name: "rule_chain", outcome: "completed",
                  detail: .init(arguments: [("action", "start")], returned: .asReturned("Not started."))),
        ]
        let trace = TurnTrace(timeline, sealedAt: epoch)
        XCTAssertNotNil(trace.toolCalls.first?.detail)
        XCTAssertNil(trace.withoutText().toolCalls.first?.detail)

        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.noteToolResult(name: "save_note", outcome: "completed", query: nil, result: "private",
                                    arguments: ["text": "private"], turnID: TurnRecorder.toolTraceID,
                                    secrets: { XCTFail("other tools' contents are never processed"); return [] })
        TurnRecorder.endTurn()
        XCTAssertNil(sunk.first?.toolCalls.first?.detail)
    }

    func testOldToolNotesDecodeWithoutEvidence() throws {
        let old = Data(#"{"name":"rule_chain","outcome":"completed"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TurnTimeline.ToolNote.self, from: old).detail)
    }
}
