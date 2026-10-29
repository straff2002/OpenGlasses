import XCTest
@testable import OpenGlasses

/// Plan JJ P2 end to end: an invented vault whose one book prints Tables 99, 98, 97 and 90 and a
/// Table 92 whose grid cannot be read, with the example `chains.md` — imported, validated, run on a
/// job by `rule_chain`, and read back onto the job's record. Every table, rule and value is
/// invented.
@MainActor
final class RuleChainSessionTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "rule_chain_test"
    private static let book = "Invented Book A"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleChainSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// The vault folder: one invented book and `chains`.
    private func vaultFolder(chains: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(printed: "12"),
                                                       TableFixtureLayouts.twoLevelHeader(),
                                                       TableFixtureLayouts.unitsInHeader(),
                                                       TableFixtureLayouts.groupingBands(),
                                                       TableFixtureLayouts.captionOverProse()]),
                                    named: "a.pdf", in: docs)
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Rule Chain Test", version: "1.0.0",
            files: ["safety.md", "chains.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "a.pdf", title: Self.book)],
            gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nIsolate before work.".write(to: dir.appendingPathComponent("safety.md"),
                                                     atomically: true, encoding: .utf8)
        try chains.write(to: dir.appendingPathComponent("chains.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func startSession(chains: String = RuleChainFixtures.chainsMarkdown) async throws
        -> (service: FieldSessionService, store: DocumentStore, warnings: [String]) {
        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let report = try VaultImporter.installReporting(from: try vaultFolder(chains: chains))
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
        return (service, store, report.warnings)
    }

    private func chain(_ args: [String: Any], _ service: FieldSessionService, _ store: DocumentStore) async throws -> String {
        try await RuleChainTool(documentStore: store, sessionService: service).execute(args: args)
    }

    // MARK: - Started on request (Plan KD P0)

    /// The retest: a chain started on a question it happened to answer, and later replaced the
    /// chain in hand the same way. Both go through 'start', and both are refused without the
    /// technician's words.
    func testAChainStartsOnlyWhenTheTechnicianAsksForIt() async throws {
        let (service, store, _) = try await startSession()
        func tool(_ said: String) -> RuleChainTool {
            RuleChainTool(documentStore: store, sessionService: service, currentUtterance: { said },
                          previousReply: { nil })
        }
        let unasked = try await tool("what's the voltage drop on a 30 metre run of 6 copper")
            .execute(args: ["action": "start", "chain": "Voltage drop on a run"])
        XCTAssertEqual(unasked, RuleChainTool.notAskedRefusal)
        XCTAssertNil(service.activeChain, "nothing started")

        let asked = try await tool("run the voltage drop on a run chain")
            .execute(args: ["action": "start", "chain": "Voltage drop on a run"])
        XCTAssertTrue(asked.contains("Started the chain 'Voltage drop on a run'"), asked)

        let replaced = try await tool("what does the conductor carry at 40 degrees")
            .execute(args: ["action": "start", "chain": "Check an installed conductor"])
        XCTAssertEqual(replaced, RuleChainTool.notAskedRefusal)
        XCTAssertEqual(service.activeChain?.chain.name, "Voltage drop on a run", "the chain in hand is left alone")
    }

    func testThePromptOffersAChainByNameAndStartsItOnlyOnRequest() async throws {
        let (service, _, _) = try await startSession()
        let idle = try XCTUnwrap(service.chainPromptContext())
        XCTAssertTrue(idle.contains("offer it by name; start it (rule_chain 'start', its name) only when they ask"), idle)
        XCTAssertFalse(idle.contains("offer it and start it"), idle)
    }

    // MARK: - Import

    func testAChainThatNamesATableTheVaultLacksIsReportedAtImportAndKeptMarked() async throws {
        let extra = RuleChainFixtures.chainsMarkdown + """


        ## Needs another book
        Answers: a value from a table this vault does not carry.

        ```chain
        ask key (text): Which row?
        lookup value = Table 89 row {key} column Value rule exact
        say "{value}"
        ```
        """
        let (service, store, warnings) = try await startSession(chains: extra)
        XCTAssertTrue(warnings.contains(VaultValidator.missingTablesWarning(file: "chains.md", chain: "Needs another book",
                                                                            missing: ["Table 89"])), "\(warnings)")
        XCTAssertEqual(warnings.filter { $0.contains("chain") }.count, 1, "the example's tables are all in the book: \(warnings)")

        // Plan JW P0: the names lead, one per line, exactly as 'start' takes them.
        let list = try await chain(["action": "list"], service, store)
        let lines = list.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(5)), [
            "Rule chains in this vault, by name:",
            "• Size a conductor for a load",
            "• Check an installed conductor",
            "• Voltage drop on a run",
            "• Needs another book (can't start: needs Table 89)",
        ], list)
        XCTAssertTrue(list.contains("Read these names to the technician as they are"), list)
        XCTAssertFalse(list.contains("answers:"), "what a chain answers is in the prompt, not the list: \(list)")
        XCTAssertEqual(list.components(separatedBy: "can't start").count, 2, "only that chain is marked: \(list)")
        XCTAssertLessThan(list.count, 400, list)
    }

    func testABadStepFailsTheImportWithItsLine() throws {
        let dir = try vaultFolder(chains: """
        ## Broken
        Answers: nothing.

        ```chain
        lokup value = Table 99 row QXRT column Rating group 1 rule exact
        say "{value}"
        ```
        """)
        let result = VaultValidator.validate(directory: dir)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.hasPrefix("chains.md line 5: Broken: unknown step 'lokup'") }, "\(result.issues)")
        XCTAssertThrowsError(try VaultImporter.installReporting(from: dir))
    }

    // MARK: - On a job

    func testAChainRunsOnTheJobAndItsReadBackLandsOnTheRecordAsAReading() async throws {
        let (service, store, _) = try await startSession()

        // Before a chain runs, the prompt offers the chains by what they answer, and chains.md is
        // not read into the core as reference text.
        let idle = try XCTUnwrap(service.promptContext())
        XCTAssertTrue(idle.contains("RULE CHAINS this vault offers"), idle)
        XCTAssertTrue(idle.contains("- Size a conductor for a load: which conductor carries a load"), idle)
        XCTAssertFalse(idle.contains("lookup factor = Table 98"), "the chain file is not core text")

        let started = try await chain(["action": "start", "chain": "size a conductor"], service, store)
        XCTAssertTrue(started.hasPrefix("Started the chain 'Size a conductor for a load'."), started)
        XCTAssertTrue(started.contains("Next, ask the technician: What load will the circuit carry, in amps? "
                                       + "(it needs a number in A, from 1 to 400)"), started)

        // The system prompt carries the current step.
        let asking = try XCTUnwrap(service.promptContext())
        XCTAssertTrue(asking.contains("ACTIVE RULE CHAIN — Size a conductor for a load (step 1 of 9):"), asking)
        XCTAssertTrue(asking.contains("Ask the technician, in your own words: What load will the circuit carry, in amps?"), asking)
        XCTAssertTrue(asking.contains("call rule_chain action 'answer'"), asking)

        let refused = try await chain(["action": "answer", "value": "4000"], service, store)
        XCTAssertTrue(refused.contains("That answer was not taken: 4000 A is outside"), refused)
        XCTAssertTrue(try XCTUnwrap(service.promptContext()).contains("Their last answer was not taken"))

        _ = try await chain(["action": "answer", "value": "32"], service, store)
        _ = try await chain(["action": "answer", "value": "14 °C"], service, store)
        let status = try await chain(["action": "status"], service, store)
        XCTAssertTrue(status.contains("step 3 of 9") && status.contains("- ambient: 14 °C, as the technician said"), status)
        XCTAssertTrue(try XCTUnwrap(service.promptContext()).contains("So far: load: 32 A, as the technician said; ambient: 14 °C"))
        _ = try await chain(["action": "answer", "value": "5"], service, store)
        let done = try await chain(["action": "answer", "value": "2"], service, store)

        XCTAssertTrue(done.contains("Finished. Say the result: Use QMX90 › two conductors: rated 45 A"), done)
        XCTAssertTrue(done.contains("6. factor: Table 98 (Correction factors), row 13-15, column Rating group 2 › Band B: 0.86"), done)
        XCTAssertTrue(done.hasSuffix("Source: \(Self.book), page 2 (printed 12), Table 99"), done)
        XCTAssertTrue(done.contains("Source: \(Self.book), page 3, Table 98"), done)
        XCTAssertNil(service.activeChain, "a finished chain ends")

        // On the job as a reading, worked by the chain.
        let session = try XCTUnwrap(service.activeSession)
        let reading = try XCTUnwrap(session.spokenReadings.last)
        XCTAssertEqual(reading.quantity, "chain: Size a conductor for a load")
        XCTAssertTrue(reading.isRuleChain)
        XCTAssertTrue(reading.value.hasPrefix("Chain: Size a conductor for a load\n1. load: 32 A"), reading.value)
        XCTAssertTrue(reading.value.contains("— follows Rule QR-17"), reading.value)
        XCTAssertTrue(session.jobEvidence.readings.contains(reading.id))

        // The record prints it where readings appear, under its own heading, every step.
        let summary = WorkRecord(session: session, vaultName: "Rule Chain Test").summary
        XCTAssertTrue(summary.contains("Rule chains worked on this job:\n  Chain: Size a conductor for a load\n  1. load: 32 A"), summary)
        XCTAssertTrue(summary.contains("  8. size: Table 99 (Conductor ratings), row QMX90 › two conductors"), summary)
        XCTAssertFalse(summary.contains("Readings reported by the technician"), "a chain is not a reading the technician said")

        // A spoken correction never lands on the chain.
        XCTAssertNil(service.correctReading(value: "40", unit: "A"), "no said reading to correct")

        // Its lookups are what "show me the table" opens.
        _ = try await ShowSourceTool(documentStore: store, sessionService: service).execute(args: ["which": "Table 98"])
        XCTAssertEqual(service.sourceCenter.presented?.pages.map(\.page), [3])

        // And the prompt is back to offering the chains.
        XCTAssertTrue(try XCTUnwrap(service.promptContext()).contains("RULE CHAINS this vault offers"))
    }

    /// Plan JN P2: a step that read a table from a picture is marked in the reading filed on the
    /// job, as a field the reading keeps and not only in its text.
    func testAReadingFiledFromAPictureKeepsTheMark() async throws {
        let (service, store, _) = try await startSession()
        let tables = service.chainTables(documentStore: store).map { source -> TableLookup.Source in
            guard source.table.label == "Table 97" else { return source }
            var table = source.table
            table.source = .recognised(reader: .documentGrid, meanConfidence: 0.9)
            return TableLookup.Source(documentId: source.documentId, documentName: source.documentName, table: table)
        }
        let drop = try XCTUnwrap(service.offeredChains.first { $0.chain.name == "Voltage drop on a run" }?.chain)
        _ = try service.startChain(drop, tables: tables)
        var progress: ChainProgress?
        for answer in ["QX6", "20", "100", "240"] { progress = try service.answerChain(answer, tables: tables) }
        guard case .finished = progress?.step else { return XCTFail("\(String(describing: progress?.step))") }
        let mark = "from a picture of Table 97 (Run lengths), PDF page 4: check it against the page"
        let reading = try XCTUnwrap(service.activeSession?.spokenReadings.last)
        XCTAssertTrue(reading.isRuleChain)
        XCTAssertEqual(reading.pictureMarks, [mark])
        XCTAssertTrue(reading.readFromPicture)
        XCTAssertTrue(reading.value.contains(mark), reading.value)

        // A chain over the text layer files no mark.
        _ = try service.startChain(drop, tables: service.chainTables(documentStore: store))
        for answer in ["QX6", "20", "100", "240"] { _ = try service.answerChain(answer, tables: service.chainTables(documentStore: store)) }
        let plain = try XCTUnwrap(service.activeSession?.spokenReadings.last)
        XCTAssertNotEqual(plain.id, reading.id)
        XCTAssertNil(plain.pictureMarks)
    }

    func testAChainThatStopsIsRecordedWithWhyAndOneTheTechnicianStopsIsNot() async throws {
        let (service, store, _) = try await startSession()
        _ = try await chain(["action": "start", "chain": "Check an installed conductor"], service, store)
        for answer in ["QXRT three conductors", "32", "14", "5"] {
            _ = try await chain(["action": "answer", "value": answer], service, store)
        }
        // Rating group 3 is not a column of Table 98.
        let stopped = try await chain(["action": "answer", "value": "3"], service, store)
        XCTAssertTrue(stopped.contains("Stopped at step 7: Table 98 has no column \"Rating group 3 › Band B\""), stopped)
        XCTAssertTrue(stopped.contains("Offer to show the page; open it with show_source only if they ask."), stopped)
        // Plan JW P0: said so that it is plainly over, the table named, no further values asked.
        XCTAssertTrue(stopped.contains("The chain 'Check an installed conductor' has ended and is not running."), stopped)
        XCTAssertTrue(stopped.contains("It could not read Table 98 at that step."), stopped)
        XCTAssertTrue(stopped.contains("Do not ask the technician for any more values for this chain"), stopped)
        XCTAssertTrue(stopped.contains("started again with rule_chain 'start', only when the technician asks"), stopped)
        XCTAssertTrue(stopped.contains("Source: \(Self.book), page 3, Table 98"), stopped)
        let reading = try XCTUnwrap(service.activeSession?.spokenReadings.last)
        XCTAssertTrue(reading.value.contains("Stopped at step 7 of 10"), reading.value)
        XCTAssertNil(service.activeChain)

        let count = service.activeSession?.spokenReadings.count
        _ = try await chain(["action": "start", "chain": "voltage drop"], service, store)
        _ = try await chain(["action": "answer", "value": "QX6"], service, store)
        let halted = try await chain(["action": "stop"], service, store)
        XCTAssertTrue(halted.contains("Stopped the chain 'Voltage drop on a run' at step 2. Nothing was recorded"), halted)
        XCTAssertEqual(service.activeSession?.spokenReadings.count, count)
        let none = try await chain(["action": "answer", "value": "20"], service, store)
        XCTAssertTrue(none.contains("No rule chain is running"), none)
    }

    func testAChainWhoseTablesCannotBeReadIsNotStarted() async throws {
        let extra = RuleChainFixtures.chainsMarkdown + """


        ## Size widgets for a load
        Answers: an invented widget size, from two tables the book cannot give.

        ```chain
        ask key (text): Which widget?
        lookup first = Table 92 row {key} column Value rule exact
        lookup second = Table 89 row {key} column Value rule exact
        say "{first} {second}"
        ```
        """
        let (service, store, _) = try await startSession(chains: extra)
        _ = try await chain(["action": "start", "chain": "Voltage drop on a run"], service, store)

        let refused = try await chain(["action": "start", "chain": "Size widgets for a load"], service, store)
        XCTAssertTrue(refused.hasPrefix("The chain 'Size widgets for a load' was not started: it needs Table 89, which no "
                                        + "loaded manual's tables include; and Table 92 (PDF page 6 of Invented Book A), "
                                        + "whose grid could not be read. Nothing was started or recorded."), refused)
        XCTAssertTrue(refused.contains("Offer to show that table's page, to work it from the book; open it with show_source only if they ask."), refused)
        XCTAssertTrue(refused.contains("manual_figure"), refused)
        XCTAssertEqual(service.activeChain?.chain.name, "Voltage drop on a run", "the running chain is left alone")
        // "Show me the table" opens the unread table's page.
        XCTAssertEqual(service.sourceCenter.memory.citations.map(\.figure), ["Table 92"])

        let list = try await chain(["action": "list"], service, store)
        XCTAssertTrue(list.contains("• Size widgets for a load (can't start: needs Table 92, Table 89)"), list)
    }

    func testStartingNeedsAJobAndANameItKnows() async throws {
        let (service, store, _) = try await startSession()
        let unknown = try await chain(["action": "start", "chain": "breaker sizing"], service, store)
        XCTAssertTrue(unknown.contains("No chain is named like \"breaker sizing\""), unknown)
        XCTAssertTrue(unknown.contains("Size a conductor for a load; Check an installed conductor; Voltage drop on a run"), unknown)

        // Plan JW P0 (owner decision): naming another chain to start replaces the running one,
        // which records nothing, as 'stop' does; naming the running one carries on with it.
        let readings = service.activeSession?.spokenReadings.count
        _ = try await chain(["action": "start", "chain": "Voltage drop on a run"], service, store)
        _ = try await chain(["action": "answer", "value": "QX6"], service, store)
        let again = try await chain(["action": "start", "chain": "voltage drop"], service, store)
        XCTAssertTrue(again.hasPrefix("The chain 'Voltage drop on a run' is already running, at step 2 of 9. It was not restarted."), again)
        XCTAssertTrue(again.contains("Next, ask the technician: What current does the run carry, in amps?"), again)
        XCTAssertEqual(service.activeChain?.answers, ["QX6"], "not restarted")

        let second = try await chain(["action": "start", "chain": "Check an installed conductor"], service, store)
        XCTAssertTrue(second.hasPrefix("Stopped 'Voltage drop on a run' at step 2; nothing was recorded. "
                                       + "Started the chain 'Check an installed conductor'.\n"), second)
        XCTAssertTrue(second.contains("Next, ask the technician: Which conductor is installed"), second)
        XCTAssertEqual(service.activeChain?.chain.name, "Check an installed conductor")
        XCTAssertEqual(service.activeSession?.spokenReadings.count, readings, "the replaced chain records nothing")

        let idle = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("idle", isDirectory: true))
        let noJob = try await RuleChainTool(documentStore: store, sessionService: idle).execute(args: ["action": "list"])
        XCTAssertTrue(noJob.contains("No active Field Assist session"), noJob)
    }
}
