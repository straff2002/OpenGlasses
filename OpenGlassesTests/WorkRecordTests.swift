import XCTest
@testable import OpenGlasses

/// Plan EM P1 — a recommendation is an object the technician decides on, and the visit renders as
/// one deterministic record.
///
/// Everything here is headless. The parts index and the acceptance path run against the real
/// example vault (`examples/vaults/lennox-slp99`), because the convention `parts.md` follows is
/// only worth anything if a real vault written to it verifies a real number; the manual-only
/// verification skips when a developer has not dropped the manuals into `documents/`.
@MainActor
final class WorkRecordTests: XCTestCase {

    private static let vaultId = "lennox_slp99"
    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private static var exampleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkRecordTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixtures

    /// A working copy of the example vault. `manualsPresent` says whether the reference tier is
    /// real; without the manuals the copy's manifest drops `documents` so the core still validates.
    private func stageExample() throws -> (directory: URL, manualsPresent: Bool) {
        let source = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(source.path)")
        }
        let copy = tempRoot.appendingPathComponent("lennox-slp99", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: copy.appendingPathComponent("manifest.json")))
        let manualsPresent = manifest.documents.allSatisfy {
            FileManager.default.fileExists(atPath: copy.appendingPathComponent(manifest.documentRelativePath($0)).path)
        }
        if !manualsPresent {
            let trimmed = VaultManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                        files: manifest.files, proceduresDir: manifest.proceduresDir,
                                        documentsDir: nil, documents: [], gating: manifest.gating,
                                        promptRules: manifest.promptRules,
                                        sourceAttributionFormat: manifest.sourceAttributionFormat,
                                        sourceAttributionRequired: manifest.sourceAttributionRequired)
            try JSONEncoder().encode(trimmed).write(to: copy.appendingPathComponent("manifest.json"))
        }
        return (copy, manualsPresent)
    }

    private func startSession(from directory: URL, store: DocumentStore? = nil,
                              jobReference: String? = nil) throws -> FieldSessionService {
        let manifest = try VaultImporter.install(from: directory)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        _ = try service.startSession(vaultId: manifest.id, assetId: nil, jobReference: jobReference)
        return service
    }

    /// The core-only session almost every test here needs.
    private func lennoxSession(jobReference: String? = nil) throws -> FieldSessionService {
        let (directory, _) = try stageExample()
        return try startSession(from: directory, jobReference: jobReference)
    }

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    // MARK: - The parts index

    func testThePartsIndexIsTheVaultsOwnTable() throws {
        let (directory, _) = try stageExample()
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.files.contains("parts.md"), "the example carries a parts file: \(manifest.files)")
        let files = try manifest.files.map {
            (filename: $0, contents: try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8))
        }
        let index = VaultPartsIndex(files: files)
        XCTAssertFalse(index.isEmpty)

        let switchKit = try XCTUnwrap(index.part(number: "14T65"))
        XCTAssertEqual(switchKit.file, "parts.md")
        XCTAssertEqual(switchKit.heading, "Conversion and high altitude")
        XCTAssertTrue(switchKit.partDescription.contains("High-altitude pressure switch"), switchKit.partDescription)
        XCTAssertTrue(switchKit.fits.contains("070"), switchKit.fits)

        // Case and stray punctuation do not matter — a spoken number picks both up.
        XCTAssertEqual(index.part(number: "14t65.")?.number, "14T65")
        // And a number nothing in the core names is simply absent.
        XCTAssertNil(index.part(number: "99Z99"))

        // Only the parts file's tables count. `models.md` prints 65W77 in prose and a specifications
        // table lives two files away; neither becomes a row.
        XCTAssertTrue(index.parts.allSatisfy { $0.file == "parts.md" }, index.parts.map(\.file).description)
        XCTAssertNotNil(index.part(number: "65W77"))
    }

    func testAPartsSectionInAnOrdinaryCoreFileIsReadAndTheRestOfTheFileIsNot() {
        let markdown = """
        # Spares

        ## Specifications

        | Part | Description | Fits |
        |---|---|---|
        | 11A11 | Not a spare, a spec row | All |

        ## Parts

        | Part | Description | Fits | Supersedes |
        |---|---|---|---|
        | 22B22 | Igniter | RTU-500 | 21B21 |

        ## Wiring

        | Part | Description | Fits |
        |---|---|---|
        | 33C33 | Also not a spare | All |
        """
        let index = VaultPartsIndex(files: [("spares.md", markdown)])
        XCTAssertEqual(index.parts.map(\.number), ["22B22"])
        // A number the table says was superseded resolves to what replaced it, because that is what
        // the technician reads off the old component.
        XCTAssertEqual(index.part(number: "21B21")?.number, "22B22")
        XCTAssertNil(index.part(number: "11A11"))
        XCTAssertNil(index.part(number: "33C33"))
    }

    // MARK: - Verification

    func testAPartInTheTableIsVerifiedAndOneNothingKnowsIsSaidSo() throws {
        let service = try lennoxSession()
        let verified = service.verifyPart("14T65")
        XCTAssertTrue(verified.verified)
        XCTAssertEqual(verified.number, "14T65")
        XCTAssertEqual(verified.page, "parts.md § Conversion and high altitude (fits 070, 090XV36C, 090XV48C, 110, 135)")

        let unknown = service.verifyPart("99Z99")
        XCTAssertFalse(unknown.verified)
        XCTAssertNil(unknown.page)
        let note = try XCTUnwrap(PartsVerifier.unverifiedNote([unknown]))
        XCTAssertTrue(note.hasPrefix("99Z99 is not in the manuals"), note)
    }

    func testAPartFoundOnlyInTheManualsCitesThePageItIsPrintedOn() async throws {
        let (directory, manualsPresent) = try stageExample()
        guard manualsPresent else { throw XCTSkip("manuals not present in documents/; see documents/README.md") }
        let store = makeStore()
        let service = try startSession(from: directory, store: store)
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: Self.vaultId))
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)

        // 67M41, the defrost tempering kit, is named on the wiring diagram and is deliberately not
        // in parts.md — so this is the manual route and nothing else.
        XCTAssertNil(service.partsIndex.part(number: "67M41"))
        let verified = service.verifyPart("67M41")
        XCTAssertTrue(verified.verified, "expected a manual hit for 67M41")
        let page = try XCTUnwrap(verified.page)
        XCTAssertTrue(page.contains("SLP99UHVK"), page)
        XCTAssertTrue(page.contains("page "), page)

        // And a number neither route knows stays unverified even with the manuals loaded.
        XCTAssertFalse(service.verifyPart("99Z99").verified)
    }

    // MARK: - propose_task

    func testARecommendationWithoutACitationIsRefused() async throws {
        let service = try lennoxSession()
        let tool = ProposeTaskTool(sessionService: service)
        let reply = try await tool.execute(args: ["title": "Replace the flame sensor"])
        XCTAssertTrue(reply.contains("A recommendation needs a citation"), reply)
        XCTAssertTrue(service.activeSession?.tasks.isEmpty == true, "nothing was recorded")

        let blank = try await tool.execute(args: ["title": "Replace the flame sensor", "citation": "   "])
        XCTAssertTrue(blank.contains("A recommendation needs a citation"), blank)
        XCTAssertTrue(service.activeSession?.tasks.isEmpty == true)
    }

    func testARecommendationNamingAProcedureTheVaultDoesNotHaveIsRefused() async throws {
        let service = try lennoxSession()
        let reply = try await ProposeTaskTool(sessionService: service).execute(args: [
            "title": "Check the pressure switch tubing",
            "citation": "SLP99UHVK Service Manual, page 39",
            "procedure_id": "not_a_procedure"
        ])
        XCTAssertTrue(reply.contains("There is no procedure 'not_a_procedure'"), reply)
        XCTAssertTrue(reply.contains("slp99_pressure_switch_lockout"), "it names what is available: \(reply)")
        XCTAssertTrue(service.activeSession?.tasks.isEmpty == true)
    }

    func testARecommendationNamesEveryPartItCouldNotVerify() async throws {
        let service = try lennoxSession()
        let reply = try await ProposeTaskTool(sessionService: service).execute(args: [
            "title": "Fit the high-altitude switch",
            "citation": "SLP99UHVK Service Manual, page 67",
            "parts": ["14T65", "99Z99"]
        ])
        XCTAssertTrue(reply.hasPrefix("I recommend Fit the high-altitude switch. Say 'do it' to add it to the job."), reply)
        XCTAssertTrue(reply.contains("14T65 (High-altitude pressure switch, 7,501–10,000 ft) — verified"), reply)
        XCTAssertTrue(reply.contains("99Z99 — unverified"), reply)
        XCTAssertTrue(reply.contains("99Z99 is not in the manuals loaded for this vault"), reply)

        let task = try XCTUnwrap(service.activeSession?.tasks.first)
        XCTAssertEqual(task.status, .recommended)
        XCTAssertEqual(task.origin, .recommended)
        XCTAssertEqual(task.parts.map(\.number), ["14T65", "99Z99"])
        XCTAssertEqual(task.parts.map(\.verified), [true, false])
    }

    // MARK: - The state machine

    func testEveryVerbMovesTheTaskAndSaysWhatItChanged() async throws {
        let service = try lennoxSession()
        let propose = ProposeTaskTool(sessionService: service)
        let task = TaskTool(sessionService: service)

        // "Later."
        _ = try await propose.execute(args: ["title": "Replace the flame sensor",
                                             "citation": "SLP99UHVK Service Manual, page 65"])
        let deferred = try await task.execute(args: ["verb": "defer"])
        XCTAssertEqual(deferred, "Deferred Replace the flame sensor. It stays on the record for the next visit.")
        XCTAssertEqual(service.activeSession?.tasks.first?.status, .deferred)

        // "Skip that" — on the *latest* recommendation, not the deferred one.
        _ = try await propose.execute(args: ["title": "Replace the pressure switch",
                                             "citation": "SLP99UHVK Service Manual, page 40"])
        let declined = try await task.execute(args: ["verb": "decline"])
        XCTAssertEqual(declined, "Declined Replace the pressure switch. It stays on the record as recommended and not done.")
        XCTAssertEqual(service.activeSession?.tasks.last?.status, .declined)

        // "Do it" on a recommendation with no procedure: it becomes the task in progress.
        _ = try await propose.execute(args: ["title": "Clean the condensate trap",
                                             "citation": "SLP99UHVK Service Manual, page 12",
                                             "safety_note": "Isolate the gas first"])
        let accepted = try await task.execute(args: ["verb": "accept"])
        XCTAssertTrue(accepted.hasPrefix("Accepted Clean the condensate trap. Safety first: Isolate the gas first."), accepted)
        XCTAssertTrue(accepted.contains("It is the task in progress now"), accepted)
        XCTAssertEqual(service.activeTask?.title, "Clean the condensate trap")

        // "Done", with what the technician said they did.
        let done = try await task.execute(args: ["verb": "done", "completion_note": "flushed it, ran clear"])
        XCTAssertEqual(done, "Closed Clean the condensate trap as done. Noted: flushed it, ran clear.")
        XCTAssertNil(service.activeTask)
        let closed = try XCTUnwrap(service.activeSession?.tasks.last)
        XCTAssertEqual(closed.status, .done)
        XCTAssertEqual(closed.completionNote, "flushed it, ran clear")
        XCTAssertNotNil(closed.completedAt)

        // "Start" picks up what was put off earlier, with nothing named.
        let started = try await task.execute(args: ["verb": "start"])
        XCTAssertEqual(started, "Started Replace the flame sensor. Readings, photos and pages go on it from here.")
        XCTAssertEqual(service.activeTask?.title, "Replace the flame sensor")

        // …and giving it up is kept on the record too.
        let abandoned = try await task.execute(args: ["verb": "abandon", "completion_note": "no spare on the van"])
        XCTAssertEqual(abandoned, "Marked Replace the flame sensor abandoned. Noted: no spare on the van.")
        XCTAssertEqual(service.activeSession?.tasks.first?.status, .abandoned)

        // A closed task cannot be moved again, and the tool says why rather than doing nothing.
        let again = try await task.execute(args: ["verb": "done", "task_id": closed.id])
        XCTAssertEqual(again, "'Clean the condensate trap' is already done.")

        // Nothing left to close: the tool suggests the verb that would work.
        let nothing = try await task.execute(args: ["verb": "done"])
        XCTAssertTrue(nothing.contains("Nothing is in progress"), nothing)

        // The audit log carries every move.
        let session = try XCTUnwrap(service.activeSession)
        let log = try String(contentsOf: tempRoot.appendingPathComponent("sessions/\(session.id)/log.jsonl"),
                            encoding: .utf8)
        for kind in ["task_proposed", "task_decision", "task_started", "task_completed"] {
            XCTAssertTrue(log.contains(kind), "\(kind) missing from the log")
        }
    }

    func testAnOperatorTaskNeedsNoRecommendation() async throws {
        let service = try lennoxSession()
        let tool = TaskTool(sessionService: service)
        let reply = try await tool.execute(args: ["verb": "add", "title": "Cleaned the condensate trap"])
        XCTAssertTrue(reply.hasPrefix("Added Cleaned the condensate trap to the job and started it."), reply)
        XCTAssertTrue(reply.contains("recorded as the technician's own"), reply)

        let task = try XCTUnwrap(service.activeSession?.tasks.first)
        XCTAssertEqual(task.origin, .operatorAdded)
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertNotNil(task.acceptedAt, "it is already running, so it is already accepted")
        XCTAssertNil(task.citation, "nobody recommended it, so there is nothing to cite")

        let done = try await tool.execute(args: ["verb": "done"])
        XCTAssertEqual(done, "Closed Cleaned the condensate trap as done.")
    }

    func testAProcedureAcceptedFromATaskClosesItWithItsOutcome() async throws {
        let service = try lennoxSession()
        _ = try await ProposeTaskTool(sessionService: service).execute(args: [
            "title": "Check the pressure switch tubing",
            "why": "E223 on a heat call",
            "citation": "SLP99UHVK Service Manual, page 39",
            "procedure_id": "slp99_pressure_switch_lockout",
            "parts": ["14T65"]
        ])
        let accepted = try await TaskTool(sessionService: service).execute(args: ["verb": "accept"])
        XCTAssertTrue(accepted.contains("Starting slp99_pressure_switch_lockout"), accepted)
        XCTAssertTrue(accepted.contains("The procedure's outcome will close this task."), accepted)
        XCTAssertEqual(service.activeProcedureId, "slp99_pressure_switch_lockout")
        XCTAssertEqual(service.activeTask?.title, "Check the pressure switch tubing")

        _ = try service.advanceProcedure(choice: "low_switch")     // confirm_code → check_vent
        XCTAssertEqual(service.activeTask?.title, "Check the pressure switch tubing",
                       "still running mid-procedure")
        let transition = try service.advanceProcedure(choice: "blocked")   // → clear_and_retest (terminal)
        guard case .completed(let outcome) = transition else {
            return XCTFail("expected the terminal step, got \(transition)")
        }
        XCTAssertEqual(outcome, "resolved")

        let task = try XCTUnwrap(service.activeSession?.tasks.first)
        XCTAssertEqual(task.status, .done, "the procedure's outcome closed it")
        XCTAssertEqual(task.procedureOutcome, "resolved")
        XCTAssertNotNil(task.completedAt)
        XCTAssertNil(service.activeTask)
    }

    // MARK: - Evidence attachment

    func testEvidenceAttachesToTheActiveTaskAndOtherwiseToTheJob() async throws {
        let service = try lennoxSession()
        let sessionId = try XCTUnwrap(service.activeSession?.id)

        // Nothing running: it belongs to the visit.
        var first = CaptureRecord(flowId: "before_readings", sessionId: sessionId,
                                  startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        first.set("gauge_psi", value: .number(118, unit: "psig"), provenance: Provenance(method: "voice_number"))
        service.logCaptureRecord(first)
        service.logPageVerified(title: "SLP99UHVK Service Manual", page: 39, source: .manufacturerPDF)
        XCTAssertEqual(service.activeSession?.jobEvidence.readings, [first.id])
        XCTAssertEqual(service.activeSession?.jobEvidence.pagesVerified, ["SLP99UHVK Service Manual, page 39"])

        // With a task running, the same calls land on the task.
        _ = try await TaskTool(sessionService: service).execute(args: ["verb": "add", "title": "Cleaned the trap"])
        var second = CaptureRecord(flowId: "after_readings", sessionId: sessionId,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_600))
        second.set("gauge_psi", value: .number(96, unit: "psig"), provenance: Provenance(method: "voice_number"))
        service.logCaptureRecord(second)
        service.logCitationOpened(Citation(kind: .manual, title: "SLP99UHVK Service Manual", page: 12), origin: .voice)
        _ = service.attachPhoto(Data("jpeg".utf8), caption: "trap after")

        let task = try XCTUnwrap(service.activeSession?.tasks.first)
        XCTAssertEqual(task.evidence.readings, [second.id])
        XCTAssertEqual(task.evidence.citationsOpened, ["SLP99UHVK Service Manual, page 12"])
        XCTAssertEqual(task.evidence.photos.count, 1)
        XCTAssertEqual(service.activeSession?.jobEvidence.readings, [first.id],
                       "the job's own reading did not move")
    }

    // MARK: - Parts requests

    func testAPartsRequestStandsWithoutATaskAndBasesAnswerChangesNothing() async throws {
        let service = try lennoxSession()
        let tool = PartsRequestTool(sessionService: service)

        let reply = try await tool.execute(args: ["part": "14T65", "quantity": 2, "urgency": "today"])
        XCTAssertTrue(reply.hasPrefix("Requested 2 × 14T65 — today."), reply)
        XCTAssertTrue(reply.contains("Verified (High-altitude pressure switch, 7,501–10,000 ft): parts.md § Conversion and high altitude"), reply)
        XCTAssertTrue(reply.contains("Tagged to the job, not to a task."), reply)

        let request = try XCTUnwrap(service.activeSession?.partsRequests.first)
        XCTAssertNil(request.taskId)
        XCTAssertEqual(request.quantity, 2)
        XCTAssertEqual(request.urgency, .today)
        XCTAssertEqual(request.status, .requested)
        XCTAssertTrue(request.part.verified)

        // A recommendation and its task are untouched by whatever base says back.
        _ = try await ProposeTaskTool(sessionService: service).execute(args: [
            "title": "Fit the high-altitude switch", "citation": "SLP99UHVK Service Manual, page 67"])
        let before = try XCTUnwrap(service.activeSession?.tasks.first)

        let answered = try await tool.execute(args: ["part": "14T65", "answer": "None in stock, three days"])
        XCTAssertTrue(answered.contains("Base says, about 2 × 14T65: None in stock, three days"), answered)
        XCTAssertTrue(answered.contains("It does not change the recommendation or the task"), answered)

        let updated = try XCTUnwrap(service.activeSession?.partsRequests.first)
        XCTAssertEqual(updated.status, .answered)
        XCTAssertEqual(updated.baseAnswer, "None in stock, three days")
        XCTAssertNotNil(updated.answeredAt)
        XCTAssertEqual(service.activeSession?.tasks.first, before, "the recommendation is exactly as it was")
    }

    func testAnUnverifiedPartIsRequestedAndSaidToBeUnverified() async throws {
        let service = try lennoxSession()
        let reply = try await PartsRequestTool(sessionService: service).execute(args: ["part": "99Z99"])
        XCTAssertTrue(reply.contains("99Z99 is not in the manuals loaded for this vault"), reply)
        let request = try XCTUnwrap(service.activeSession?.partsRequests.first)
        XCTAssertFalse(request.part.verified, "it is still recorded — just not as verified")
        XCTAssertEqual(request.part.number, "99Z99")
    }

    // MARK: - Codable

    func testTheSessionRoundTripsTheNewFieldsAndOlderSessionsStillDecode() throws {
        var session = Self.scriptedSession()
        session.jobEvidence.photos.append("second.jpg")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FieldSession.self, from: try encoder.encode(session))
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.tasks.count, 3)
        XCTAssertEqual(decoded.partsRequests.count, 1)
        XCTAssertEqual(decoded.identityFields.first?.source, .nameplate)
        XCTAssertEqual(decoded.jobReference, "WO-4471")

        // A session written before any of this existed decodes with empty collections rather than
        // failing — a synthesized decoder would have thrown on the missing `tasks` key.
        let old = """
        {"id":"s0","vaultId":"lennox_slp99","mode":"ai_only","startedAt":"2026-01-02T03:04:05Z",
         "outcome":"in_progress","escalations":[],"billableSeconds":0}
        """
        let legacy = try decoder.decode(FieldSession.self, from: Data(old.utf8))
        XCTAssertTrue(legacy.tasks.isEmpty)
        XCTAssertTrue(legacy.partsRequests.isEmpty)
        XCTAssertTrue(legacy.identityFields.isEmpty)
        XCTAssertTrue(legacy.jobEvidence.isEmpty)
        XCTAssertNil(legacy.jobReference)
    }

    // MARK: - The record

    func testASessionThatNeverIdentifiedAMachinePrintsNoEquipmentLine() {
        // The work order's own summary omits the line entirely in this case; the record follows the
        // same rule, so the two halves of one PDF cannot disagree about whether the machine was known.
        var session = Self.scriptedSession()
        session.equipment = nil
        let lines = WorkRecord(session: session, vaultName: "Lennox SLP99 Furnace Service").summaryLines
        XCTAssertFalse(lines.contains { $0.contains("Equipment:") }, lines.description)
        XCTAssertEqual(lines[1], "Work order asset: Unit 47B; no machine was identified.")

        // `assetId` is immutable on the session, so the no-asset case is built from scratch.
        let anonymous = FieldSession(
            id: "s2", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, pausedAt: nil,
            resumedAt: nil, outcome: .inProgress, startLocation: nil, endLocation: nil,
            escalations: [], billableSeconds: 0)
        let bare = WorkRecord(session: anonymous, vaultName: "Lennox SLP99 Furnace Service").summaryLines
        XCTAssertFalse(bare.contains { $0.contains("Equipment:") || $0.contains("Work order asset") },
                       bare.description)
    }

    func testTheRecordRendersDeterministicallyFromAScriptedSession() {
        let record = WorkRecord(session: Self.scriptedSession(), vaultName: "Lennox SLP99 Furnace Service")
        XCTAssertEqual(record.summaryLines, [
            "Job WO-4471 — Lennox SLP99 Furnace Service.",
            "Equipment: SLP99UH090XV60CK (from the nameplate), work order asset Unit 47B.",
            "  Serial: 5820A12345 (from the nameplate)",
            "Done: Check the pressure switch tubing. Why: E223 on a heat call. "
                + "Procedure slp99_pressure_switch_lockout finished as resolved. Note: cleared the tubing. "
                + "Parts: 14T65 (High-altitude pressure switch) — verified, parts.md § Conversion and high altitude. "
                + "1 reading, 1 page verified. Cited SLP99UHVK Service Manual, page 39. 12 minutes.",
            "Done: Cleaned the condensate trap (added by the technician). 3 minutes.",
            "Declined: Replace the flame sensor. Cited SLP99UHVK Service Manual, page 65.",
            "Against the job itself: 1 photo.",
            "Parts requested:",
            "  2 × 14T65 (High-altitude pressure switch) — verified, parts.md § Conversion and high altitude — today, not on the van. Base: None in stock, three days",
            "Pages verified against the manufacturer's document: SLP99UHVK Service Manual, page 39.",
            "Escalated: Readings did not match the flowchart (resolved).",
            "Time on site: 25 minutes."
        ])

        // The derived views agree with the lines.
        XCTAssertEqual(record.partsUsed.map(\.number), ["14T65"])
        XCTAssertEqual(record.notDone.map(\.title), ["Replace the flame sensor"])
        XCTAssertEqual(record.readings, ["pressure_readings@1970-01-01T00:00:00Z"])
        XCTAssertEqual(record.billableMinutes, 25)
    }

    func testTheRecordJSONRoundTripsAndIsStable() throws {
        let record = WorkRecord(session: Self.scriptedSession(), vaultName: "Lennox SLP99 Furnace Service")
        let data = record.json
        XCTAssertEqual(data, record.json, "the same record encodes to the same bytes")

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkRecord.self, from: data)
        XCTAssertEqual(decoded, record)

        let text = record.jsonString
        XCTAssertTrue(text.contains("\"job_reference\" : \"WO-4471\""), text.prefix(400).description)
        XCTAssertTrue(text.contains("\"parts_requests\""), text.prefix(400).description)
    }

    func testReadBackSpeaksTheRecordAtAnyPointInTheJob() async throws {
        let service = try lennoxSession(jobReference: "WO-4471")
        _ = try await TaskTool(sessionService: service).execute(args: ["verb": "add", "title": "Cleaned the trap"])
        let spoken = try await TaskTool(sessionService: service).execute(args: ["read_back": true])
        XCTAssertTrue(spoken.hasPrefix("Job WO-4471 — Lennox SLP99 Furnace Service."), spoken)
        XCTAssertTrue(spoken.contains("In progress: Cleaned the trap (added by the technician)."), spoken)
        XCTAssertTrue(spoken.contains("No escalations."), spoken)
    }

    // MARK: - Export and queue

    func testTheExportCarriesTheRecordInJSONAndInThePDF() async throws {
        let service = try lennoxSession(jobReference: "WO-4471")
        _ = try await ProposeTaskTool(sessionService: service).execute(args: [
            "title": "Check the pressure switch tubing",
            "citation": "SLP99UHVK Service Manual, page 39",
            "parts": ["14T65"]])
        _ = try await TaskTool(sessionService: service).execute(args: ["verb": "accept"])
        _ = try await TaskTool(sessionService: service).execute(args: ["verb": "done",
                                                                      "completion_note": "cleared the tubing"])
        _ = try await PartsRequestTool(sessionService: service).execute(args: ["part": "14T65", "quantity": 2])
        let session = try service.endSession(outcome: .resolved)

        let dir = tempRoot.appendingPathComponent("sessions/\(session.id)", isDirectory: true)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        let record = try XCTUnwrap(export.workRecord)
        XCTAssertEqual(record.jobReference, "WO-4471")
        XCTAssertEqual(record.tasks(status: .done).map(\.title), ["Check the pressure switch tubing"])
        XCTAssertEqual(record.partsRequests.map(\.quantity), [2])

        // …and it survives the write → decode round trip, and reaches the PDF.
        let urls = try SessionExporter.export(sessionDir: dir, formats: [.json, .pdf])
        XCTAssertEqual(urls.count, 2)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(
            SessionExport.self, from: Data(contentsOf: dir.appendingPathComponent("audit_export.json")))
        XCTAssertEqual(reloaded.workRecord, record)
        let pdf = try Data(contentsOf: dir.appendingPathComponent("work_order.pdf"))
        XCTAssertEqual(pdf.prefix(4), Data("%PDF".utf8))
        XCTAssertGreaterThan(pdf.count, 800)
    }

    func testTheQueueCarriesTheRecordAndEachPartsRequest() async throws {
        let queuePath = tempRoot.appendingPathComponent("queue.sqlite")
        let queue = OfflineQueue(path: queuePath)
        defer { for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: queuePath.path + suffix)) } }

        let service = try lennoxSession(jobReference: "WO-4471")
        service.offlineQueue = queue
        _ = try await PartsRequestTool(sessionService: service).execute(args: ["part": "14T65", "quantity": 2])
        XCTAssertEqual(queue.pending().filter { $0.kind == .partsRequest }.count, 1,
                       "a stock check leaves before the job is finished")

        _ = try service.endSession(outcome: .resolved)
        let ops = queue.pending()
        let recordOp = try XCTUnwrap(ops.first { $0.kind == .workRecord })
        let requestOp = try XCTUnwrap(ops.first { $0.kind == .partsRequest })

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkRecord.self, from: recordOp.payload)
        XCTAssertEqual(record.jobReference, "WO-4471")
        XCTAssertEqual(record.partsRequests.count, 1)
        let request = try decoder.decode(PartsRequest.self, from: requestOp.payload)
        XCTAssertEqual(request.part.number, "14T65")
        XCTAssertEqual(request.quantity, 2)
    }

    // MARK: - Fixture

    /// A visit with fixed timestamps: two tasks done, one declined, a reading against the job, an
    /// answered parts request and a resolved escalation. Nothing here touches the clock, so the
    /// record it renders is the same on every run.
    static func scriptedSession() -> FieldSession {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var session = FieldSession(
            id: "s1", vaultId: "lennox_slp99", assetId: "Unit 47B", mode: .aiOnly,
            startedAt: t0, endedAt: t0.addingTimeInterval(1500), pausedAt: nil, resumedAt: nil,
            outcome: .resolved, startLocation: nil, endLocation: nil,
            escalations: [.init(timestamp: t0.addingTimeInterval(1000),
                                reason: "Readings did not match the flowchart",
                                resolvedAt: t0.addingTimeInterval(1200))],
            billableSeconds: 1500)
        session.jobReference = "WO-4471"
        session.equipment = EquipmentIdentity(
            modelToken: "SLP99UH090XV60CK", heading: "SLP99UH090XV60CK (090XV60C; C cabinet)",
            file: "models.md", source: .nameplate, recognisedAt: t0)
        session.identityFields = [
            DeviceIdentityField(name: "Serial", value: "5820A12345", source: .nameplate, recordedAt: t0)
        ]
        let switchPart = TaskPart(number: "14T65",
                                  partDescription: "High-altitude pressure switch",
                                  verified: true,
                                  page: "parts.md § Conversion and high altitude")
        session.tasks = [
            FieldSession.Task(
                id: "t1", title: "Check the pressure switch tubing", why: "E223 on a heat call",
                origin: .recommended, status: .done,
                procedureId: "slp99_pressure_switch_lockout", procedureOutcome: "resolved",
                citation: "SLP99UHVK Service Manual, page 39",
                parts: [switchPart],
                evidence: FieldSession.Evidence(
                    readings: ["pressure_readings@1970-01-01T00:00:00Z"],
                    pagesVerified: ["SLP99UHVK Service Manual, page 39"]),
                completionNote: "cleared the tubing",
                createdAt: t0, acceptedAt: t0.addingTimeInterval(60),
                completedAt: t0.addingTimeInterval(780)),
            FieldSession.Task(
                id: "t2", title: "Cleaned the condensate trap", origin: .operatorAdded, status: .done,
                createdAt: t0.addingTimeInterval(800), acceptedAt: t0.addingTimeInterval(800),
                completedAt: t0.addingTimeInterval(980)),
            FieldSession.Task(
                id: "t3", title: "Replace the flame sensor", origin: .recommended, status: .declined,
                citation: "SLP99UHVK Service Manual, page 65", createdAt: t0.addingTimeInterval(1100))
        ]
        session.partsRequests = [
            PartsRequest(id: "r1", part: switchPart, quantity: 2, urgency: .today,
                         status: .answered, baseAnswer: "None in stock, three days",
                         createdAt: t0.addingTimeInterval(1000),
                         answeredAt: t0.addingTimeInterval(1300))
        ]
        session.jobEvidence.photos = ["trap.jpg"]
        return session
    }
}
