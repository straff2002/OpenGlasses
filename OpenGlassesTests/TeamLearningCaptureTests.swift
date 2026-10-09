import XCTest
@testable import OpenGlasses

/// Plan FP P1 — "note this for the team": a candidate is filed against the job it was worked out
/// on, can be read back, amended and withdrawn by its author, is refused whole when it breaks the
/// contract's text rules, and is gated on the team-learning capability and withheld in HIPAA mode.
///
/// Headless: a fresh `FieldSessionService` over a temporary directory, a fresh candidate store,
/// and the bundled `refrigeration` vault. Nothing here touches the glasses or a `.shared` service's
/// camera.
@MainActor
final class TeamLearningCaptureTests: XCTestCase {

    private var root: URL!
    private var sessions: FieldSessionService!
    private var store: LearningCandidateStore!
    private var service: LearningCandidateService!
    private var tool: TeamLearningTool!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousHipaa = false

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLearningCapture-\(UUID().uuidString)", isDirectory: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()
        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        store = LearningCandidateStore(directory: root.appendingPathComponent("store", isDirectory: true))
        service = LearningCandidateService(store: store, sessions: sessions)
        service.authorName = { "Sam Tane" }
        tool = TeamLearningTool(service: service)
    }

    override func tearDown() {
        tool = nil
        service = nil
        store = nil
        sessions = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        Config.hipaaMode = previousHipaa
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func startJob(reference: String? = "WO-4471") throws -> FieldSession {
        try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: reference)
    }

    private func identify(_ model: String) {
        sessions.setEquipment(.init(modelToken: model, heading: model, file: "models.md", source: .spoken))
    }

    private func logReading(_ volts: Double) throws {
        let session = try XCTUnwrap(sessions.activeSession)
        // A capture record's id is its flow and its start second, so each reading gets a flow of
        // its own rather than colliding with the one before it.
        var record = CaptureRecord(flowId: "meter-\(UUID().uuidString.prefix(8))", sessionId: session.id)
        record.set("supply", value: .number(volts, unit: "V"), provenance: .init(method: "voice_number"))
        sessions.logCaptureRecord(record)
    }

    private func note(_ finding: String, symptom: String? = nil, fix: String? = nil,
                      model: String? = nil) async throws -> String {
        var args: [String: Any] = ["action": "note", "finding": finding]
        if let symptom { args["symptom"] = symptom }
        if let fix { args["fix"] = fix }
        if let model { args["model"] = model }
        return try await tool.execute(args: args)
    }

    // MARK: - note

    func testNoteFilesACandidateBoundToTheJobTheMachineAndTheRunningTask() async throws {
        let session = try startJob()
        identify("SLP99UH090XV60CK")
        let task = try sessions.addOperatorTask(title: "Check the pressure switch")
        try logReading(24)

        let spoken = try await note("The pressure switch tubing sweats and reads open on a cold start",
                                    symptom: "Lockout on first call for heat", fix: "Re-route the tubing")

        XCTAssertTrue(spoken.hasPrefix("Filed for the team, awaiting your supervisor's review"), spoken)
        XCTAssertTrue(spoken.contains(TeamLearningTool.standingRule), spoken)
        XCTAssertTrue(spoken.contains(TeamLearningTool.notInUse), spoken)
        XCTAssertTrue(spoken.contains("Filed against the SLP99UH090XV60CK, on the running task."), spoken)

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.candidates.count, 1)
        XCTAssertEqual(candidate.id.count, 32)
        XCTAssertTrue(candidate.id.allSatisfy { "0123456789abcdef".contains($0) }, candidate.id)
        XCTAssertEqual(candidate.origin, .spoken)
        XCTAssertEqual(candidate.status, .filed)
        XCTAssertEqual(candidate.revision, 1)
        XCTAssertEqual(candidate.sessionId, session.id)
        XCTAssertEqual(candidate.jobReference, "WO-4471")
        XCTAssertEqual(candidate.vaultId, "refrigeration")
        XCTAssertEqual(candidate.taskId, task.id)
        XCTAssertEqual(candidate.modelToken, "SLP99UH090XV60CK")
        XCTAssertNil(candidate.spokenModel, "an identified machine is not a spoken one")
        XCTAssertEqual(candidate.finding, "The pressure switch tubing sweats and reads open on a cold start")
        XCTAssertEqual(candidate.symptom, "Lockout on first call for heat")
        XCTAssertEqual(candidate.fix, "Re-route the tubing")
        XCTAssertEqual(candidate.author, "Sam Tane")
        XCTAssertEqual(candidate.redactions, [])
        // The running task's evidence, as names and counts.
        XCTAssertEqual(candidate.evidence.readings, 1)
        XCTAssertEqual(candidate.evidence.photos, 0)

        // The job records that it was filed, and nothing of what it says.
        let reference = try XCTUnwrap(sessions.activeSession?.teamLearnings?.first)
        XCTAssertEqual(reference, LearningCandidateReference(candidateId: candidate.id, status: .filed,
                                                             modelToken: "SLP99UH090XV60CK",
                                                             createdAt: candidate.createdAt))
        XCTAssertFalse(reference.inUse)
    }

    func testACandidateFiledWithNoTaskRunningLandsOnTheJobsEvidence() async throws {
        try startJob()
        try logReading(240)
        try logReading(24)
        XCTAssertNil(sessions.activeTask)

        _ = try await note("Board resets when the inducer starts", model: "Rheem 090")

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertNil(candidate.taskId)
        XCTAssertEqual(candidate.evidence, LearningCandidate.Evidence(try XCTUnwrap(sessions.activeSession).jobEvidence))
        XCTAssertEqual(candidate.evidence.readings, 2)
        XCTAssertNil(candidate.equipment)
        XCTAssertEqual(candidate.spokenModel, "Rheem 090", "with nothing identified, the model as it was said")

        // A copy, not a link: evidence recorded afterwards is not the evidence it was filed on.
        try logReading(12)
        XCTAssertEqual(store.candidate(id: candidate.id)?.evidence.readings, 2)
    }

    func testNoteNeedsAnOpenJobAndAFinding() async throws {
        let refused = try await note("The tubing sweats on a cold start")
        XCTAssertEqual(refused, LearningCandidateService.Refusal.noActiveJob.spoken)
        try startJob()
        let empty = try await tool.execute(args: ["action": "note", "finding": "   "])
        XCTAssertEqual(empty, LearningCandidateText.Refusal.missingFinding.spoken)
        let absent = try await tool.execute(args: ["action": "note", "symptom": "Lockout"])
        XCTAssertEqual(absent, LearningCandidateText.Refusal.missingFinding.spoken)
        XCTAssertTrue(store.candidates.isEmpty)
    }

    // MARK: - list

    func testListReadsTheAuthorsOwnCandidatesBackWithTheirStatus() async throws {
        let empty = try await tool.execute(args: ["action": "list"])
        XCTAssertEqual(empty, "You haven't filed any team learnings on this phone.")

        try startJob()
        identify("MODEL070")
        _ = try await note("First finding about the igniter")
        _ = try await note("Second finding about the flame sensor")
        let first = try XCTUnwrap(store.newestFirst.last)
        _ = try await tool.execute(args: ["action": "withdraw", "id": first.shortHandle])

        let listed = try await tool.execute(args: ["action": "list"])
        XCTAssertTrue(listed.contains("never use them to answer a question"), listed)
        let second = try XCTUnwrap(listed.range(of: "Second finding about the flame sensor"))
        let withdrawn = try XCTUnwrap(listed.range(of: "Id \(first.shortHandle)"))
        XCTAssertLessThan(second.lowerBound, withdrawn.lowerBound, "newest first")
        XCTAssertTrue(listed.contains("filed, awaiting review"), listed)
        XCTAssertTrue(listed.contains("withdrawn."), listed)
        XCTAssertFalse(listed.contains("First finding"), "a withdrawn candidate's words are gone")
    }

    // MARK: - amend

    func testAmendTheLastOneReplacesWhatWasSaidAndKeepsTheRest() async throws {
        try startJob()
        _ = try await note("Tubing sweats", symptom: "Lockout", fix: "Re-route")
        let original = try XCTUnwrap(store.candidates.first)

        let spoken = try await tool.execute(args: ["action": "amend", "id": "the last one",
                                                   "finding": "Tubing sweats and reads open on a cold start"])
        XCTAssertTrue(spoken.hasPrefix("Amended team learning \(original.shortHandle)"), spoken)
        XCTAssertTrue(spoken.contains(TeamLearningTool.standingRule), spoken)
        let amended = try XCTUnwrap(store.candidate(id: original.id))
        XCTAssertEqual(amended.finding, "Tubing sweats and reads open on a cold start")
        XCTAssertEqual(amended.symptom, "Lockout", "what was not said again is kept")
        XCTAssertEqual(amended.fix, "Re-route")
        XCTAssertEqual(amended.revision, 2)
        XCTAssertEqual(amended.createdAt, original.createdAt)

        // By an id prefix, and with nothing to change.
        _ = try await tool.execute(args: ["action": "amend", "id": String(original.id.prefix(5)), "fix": "New tubing"])
        XCTAssertEqual(store.candidate(id: original.id)?.fix, "New tubing")
        XCTAssertEqual(store.candidate(id: original.id)?.revision, 3)
        let nothing = try await tool.execute(args: ["action": "amend"])
        XCTAssertEqual(nothing, LearningCandidateService.Refusal.nothingToAmend.spoken)
        let unknown = try await tool.execute(args: ["action": "amend", "id": "zzzz", "fix": "x y z"])
        XCTAssertEqual(unknown, LearningCandidateService.Refusal.notFound("zzzz").spoken)
    }

    // MARK: - withdraw

    func testWithdrawKeepsTheRecordEmptiesItsTextAndTellsTheJob() async throws {
        try startJob()
        _ = try await note("Inducer bearing whines before it fails", symptom: "Whine", fix: "Replace inducer")
        let filed = try XCTUnwrap(store.candidates.first)

        let spoken = try await tool.execute(args: ["action": "withdraw"])
        XCTAssertTrue(spoken.hasPrefix("Withdrew team learning \(filed.shortHandle)."), spoken)

        let withdrawn = try XCTUnwrap(store.candidate(id: filed.id))
        XCTAssertTrue(withdrawn.withdrawn)
        XCTAssertEqual(withdrawn.status, .withdrawn)
        XCTAssertEqual(withdrawn.finding, "")
        XCTAssertNil(withdrawn.symptom)
        XCTAssertNil(withdrawn.fix)
        XCTAssertEqual(withdrawn.revision, 2)
        XCTAssertEqual(store.candidates.count, 1, "kept, not deleted")
        XCTAssertEqual(sessions.activeSession?.teamLearnings?.first?.status, .withdrawn)
        XCTAssertEqual(sessions.workRecord()?.teamLearnings?.first?.status, .withdrawn)

        let again = try await tool.execute(args: ["action": "withdraw", "id": filed.id])
        XCTAssertEqual(again, LearningCandidateService.Refusal.alreadyWithdrawn.spoken)
        let amend = try await tool.execute(args: ["action": "amend", "id": filed.id, "finding": "new words here"])
        XCTAssertEqual(amend, LearningCandidateService.Refusal.alreadyWithdrawn.spoken)
    }

    func testWithdrawingACandidateFromAnEarlierJobUpdatesThatJobsRecord() async throws {
        let first = try startJob(reference: "WO-1")
        _ = try await note("Earlier job finding about the igniter")
        _ = try sessions.endSession()
        try startJob(reference: "WO-2")

        _ = try await tool.execute(args: ["action": "withdraw"])
        XCTAssertEqual(sessions.history.first { $0.id == first.id }?.teamLearnings?.first?.status, .withdrawn)
        XCTAssertNil(sessions.activeSession?.teamLearnings, "nothing was filed on the open job")
        // …and the finished job's record on disk says so after a restart.
        let restored = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertEqual(restored.history.first { $0.id == first.id }?.teamLearnings?.first?.status, .withdrawn)
    }

    // MARK: - Text rules

    func testOverLengthInputIsRefusedWithTheReasonAndNothingIsFiled() async throws {
        try startJob()
        let long = String(repeating: "a", count: LearningCandidateText.findingLimit + 1)
        let refused = try await note(long)
        XCTAssertEqual(refused, LearningCandidateText.Refusal.tooLong(.finding, count: 2_001, limit: 2_000).spoken)
        XCTAssertTrue(refused.contains("at most"), refused)
        XCTAssertTrue(refused.hasPrefix("Nothing was filed"), refused)

        let longSymptom = try await note("A finding that fits", symptom: String(repeating: "b", count: 501))
        XCTAssertEqual(longSymptom, LearningCandidateText.Refusal.tooLong(.symptom, count: 501, limit: 500).spoken)
        let longFix = try await note("A finding that fits", fix: String(repeating: "c", count: 501))
        XCTAssertEqual(longFix, LearningCandidateText.Refusal.tooLong(.fix, count: 501, limit: 500).spoken)
        XCTAssertTrue(store.candidates.isEmpty)

        // Exactly at the limit is accepted.
        _ = try await note(String(repeating: "a", count: LearningCandidateText.findingLimit))
        XCTAssertEqual(store.candidates.count, 1)
    }

    func testControlCharactersAreRefusedAndLineBreaksNormalised() async throws {
        try startJob()
        let bell = try await note("Tubing sweats\u{0007} on a cold start")
        XCTAssertEqual(bell, LearningCandidateText.Refusal.controlCharacter(.finding).spoken)
        let escape = try await note("A finding that fits", symptom: "Lockout\u{001B}[31m")
        XCTAssertEqual(escape, LearningCandidateText.Refusal.controlCharacter(.symptom).spoken)
        let bidi = try await note("A finding that fits", fix: "Re-route \u{202E}gnibut")
        XCTAssertEqual(bidi, LearningCandidateText.Refusal.controlCharacter(.fix).spoken)
        XCTAssertTrue(store.candidates.isEmpty)

        // Tabs and carriage returns are how dictation breaks lines: normalised, not refused. A line
        // feed survives inside the finding only.
        _ = try await note("  First line\r\nSecond\tline  ", symptom: "Lockout\non start", fix: "Re-route\r")
        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(candidate.finding, "First line\nSecond line")
        XCTAssertEqual(candidate.symptom, "Lockout on start")
        XCTAssertEqual(candidate.fix, "Re-route")
    }

    func testTheAuthorIsPlainAndBounded() {
        XCTAssertEqual(LearningCandidateText.author("  Sam\u{0007} Tane "), "Sam  Tane")
        XCTAssertEqual(LearningCandidateText.author(""), "Technician")
        XCTAssertEqual(LearningCandidateText.author(String(repeating: "x", count: 300)).count,
                       LearningCandidateText.authorLimit)
    }

    // MARK: - Gates

    func testTheCapabilityGateRefusesWithTheChecksReason() async throws {
        try startJob()
        service.capability = { .notIncluded(held: [.bundledVaults, .ownVaults]) }
        let notIncluded = try await note("The tubing sweats on a cold start")
        XCTAssertEqual(notIncluded, FieldAssistPaywallCopy.teamLearningsNotIncluded)
        service.capability = { .denied(.expired(Date(timeIntervalSince1970: 0))) }
        let lapsed = try await note("The tubing sweats on a cold start")
        XCTAssertEqual(lapsed, FieldAssistPaywallCopy.teamLearningsLapsed)
        service.capability = { .denied(.noEvidence) }
        let locked = try await note("The tubing sweats on a cold start")
        XCTAssertEqual(locked, FieldAssistPaywallCopy.teamLearningsLocked)
        service.capability = { .denied(.unverifiableLicense) }
        let unverifiable = try await note("The tubing sweats on a cold start")
        XCTAssertEqual(unverifiable, FieldAssistPaywallCopy.unverifiable)
        XCTAssertTrue(store.candidates.isEmpty)
    }

    func testASubscriberIsRefusedThroughTheRealEntitlementAndATeamLicenceIsNot() async throws {
        try startJob()
        let real = LearningCandidateService(store: store, sessions: sessions)
        let realTool = TeamLearningTool(service: real)

        FieldAssistEntitlement.shared.provider = StubEntitlementProvider.subscriber()
        XCTAssertTrue(Config.fieldAssistActive, "a subscriber has Field Assist — just not team learnings")
        XCTAssertEqual(FieldAssistEntitlement.shared.check(.teamLearnings), .notIncluded(held: [.bundledVaults, .ownVaults]))
        let refused = try await realTool.execute(args: ["action": "note", "finding": "Tubing sweats on a cold start"])
        XCTAssertEqual(refused, FieldAssistPaywallCopy.teamLearningsNotIncluded)
        XCTAssertTrue(store.candidates.isEmpty)

        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .team)
        _ = try await realTool.execute(args: ["action": "note", "finding": "Tubing sweats on a cold start"])
        XCTAssertEqual(store.candidates.count, 1)

        // Reading your own back and taking one back are not gated: neither adds anything.
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider.subscriber()
        let listed = try await realTool.execute(args: ["action": "list"])
        XCTAssertTrue(listed.contains("Tubing sweats on a cold start"), listed)
        _ = try await realTool.execute(args: ["action": "withdraw"])
        XCTAssertEqual(store.candidates.first?.status, .withdrawn)
    }

    func testTheToolRefusesWhenFieldAssistIsOff() async throws {
        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        let spoken = try await tool.execute(args: ["action": "note", "finding": "Tubing sweats on a cold start"])
        XCTAssertTrue(spoken.hasPrefix("Field Assist is disabled"), spoken)
        XCTAssertTrue(store.candidates.isEmpty)
    }

    func testHIPAAModeWithholdsTheToolFromTheRegistry() {
        // Built without the Field Assist tools, and the one under test registered by hand, so the
        // registry constructs nothing it does not need.
        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        let registry = NativeToolRegistry(locationService: LocationService())
        XCTAssertNil(registry.tool(named: "team_learning"), "registered only while Field Assist is on")
        registry.register(TeamLearningTool(service: service))
        XCTAssertNotNil(registry.tool(named: "team_learning"))
        XCTAssertTrue(registry.toolNames.contains("team_learning"))

        Config.hipaaMode = true
        XCTAssertTrue(Config.hipaaDisabledTools.contains("team_learning"))
        XCTAssertNil(registry.tool(named: "team_learning"), "a clinical site's learning is a patient note")
        XCTAssertFalse(registry.toolNames.contains("team_learning"))
    }

    func testTheToolIsOfferedDuringAJobAndWorksOffline() {
        XCTAssertTrue(FieldToolProfile.names.contains("team_learning"))
        XCTAssertEqual(OfflineToolPolicy.table["team_learning"], .local)
        XCTAssertEqual(TeamLearningTool().executionSemantics, .local())
    }

    // MARK: - Decoding old and new

    func testOldSessionsAndRecordsDecodeWithoutTheField() throws {
        let session = try startJob()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        XCTAssertNil(json["teamLearnings"], "a job that filed nothing writes no key")
        json.removeValue(forKey: "teamLearnings")
        let legacy = try JSONDecoder().decode(FieldSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.teamLearnings)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let plain = try XCTUnwrap(sessions.workRecord())
        XCTAssertFalse(plain.jsonString.contains("team_learnings"), "an older record encodes exactly as it did")
        XCTAssertNil(try decoder.decode(WorkRecord.self, from: plain.json).teamLearnings)
    }

    func testTheFoldRoundTripsAndAnOlderExportStillDecodes() async throws {
        let session = try startJob()
        _ = try await note("Tubing sweats on a cold start")
        let candidate = try XCTUnwrap(store.candidates.first)
        _ = try sessions.endSession()

        let dir = root.appendingPathComponent("sessions/\(session.id)", isDirectory: true)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertEqual(export.workRecord?.teamLearnings?.map(\.candidateId), [candidate.id])

        // A record going to a customer does not mention it (contract §8).
        let customer = ReportTranscriptPolicy.decide(channel: .email, recipients: ["someone@example.org"],
                                                     carriesFiles: true, context: .init())
        XCTAssertEqual(customer.audience, .customer)
        let customerExport = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir, transcript: customer))
        XCTAssertNotNil(customerExport.workRecord)
        XCTAssertNil(customerExport.workRecord?.teamLearnings)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(export)
        XCTAssertEqual(try decoder.decode(SessionExport.self, from: data).workRecord?.teamLearnings,
                       export.workRecord?.teamLearnings)

        // The same export as a build before this phase wrote it: no `team_learnings` key at all.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var record = try XCTUnwrap(object["workRecord"] as? [String: Any] ?? object["work_record"] as? [String: Any])
        XCTAssertNotNil(record.removeValue(forKey: "team_learnings"))
        object[object["workRecord"] != nil ? "workRecord" : "work_record"] = record
        let legacy = try decoder.decode(SessionExport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotNil(legacy.workRecord)
        XCTAssertNil(legacy.workRecord?.teamLearnings)
    }

    func testEveryOriginDecodesAndTheRecordUsesTheContractsNames() throws {
        XCTAssertEqual(LearningCandidate.Origin.allCases.map(\.rawValue), ["spoken", "report", "reportReview"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for origin in LearningCandidate.Origin.allCases {
            let candidate = LearningCandidate(origin: origin, sessionId: "s1", jobReference: "1007", taskId: "t1",
                                              vaultId: "refrigeration", equipment: nil, spokenModel: "Rheem 090",
                                              finding: "Board resets", symptom: nil, fix: nil,
                                              evidence: .init(pagesVerified: ["Manual, page 3"], readings: 2),
                                              author: "Sam", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                              redactions: ["email"])
            let data = try encoder.encode(candidate)
            XCTAssertEqual(try decoder.decode(LearningCandidate.self, from: data), candidate)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for key in ["candidateID", "jobSessionID", "jobNumber", "taskID", "vaultID", "spokenModel",
                        "finding", "evidence", "author", "redactions", "revision", "origin"] {
                XCTAssertNotNil(object[key], "contract field \(key) missing")
            }
            let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
            XCTAssertEqual(evidence["readings"] as? Int, 2, "readings are a count, never values")
        }
    }

    // MARK: - The phrase

    func testThePhraseFilesTheTechniciansOwnWordsWithoutAModel() {
        let classifier = ConversationClassifier()
        let spoken = "Note this for the team — on the 090 the pressure switch tubing sweats and reads open on a cold start."
        let call = classifier.classify(spoken).directToolCall
        XCTAssertEqual(call?.toolName, "team_learning")
        XCTAssertEqual(call?.arguments["action"] as? String, "note")
        XCTAssertEqual(call?.arguments["finding"] as? String,
                       "on the 090 the pressure switch tubing sweats and reads open on a cold start.",
                       "verbatim, case and all — the technician's words, not a paraphrase")

        for variant in ["note this for the team: the 070 igniter cracks when cold",
                        "Please log that for the team, the 070 igniter cracks when cold",
                        "ok note for the team the 070 igniter cracks when cold"] {
            XCTAssertEqual(classifier.classify(variant).directToolCall?.toolName, "team_learning", variant)
        }
        // A bare phrase is a question the model asks back, and the same words inside a sentence are
        // not a filing.
        for notAFiling in ["note this for the team", "note this for the team, please",
                           "can you note this for the team later", "what does note this for the team do",
                           "note for the teams list the 070 igniter"] {
            XCTAssertNotEqual(classifier.classify(notAFiling).directToolCall?.toolName, "team_learning", notAFiling)
        }
    }

    // MARK: - The store

    func testTheStoreFileIsExcludedFromBackupAndSurvivesARestart() async throws {
        try startJob()
        _ = try await note("Tubing sweats on a cold start")
        let values = try store.fileLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(SensitiveStore.learningCandidates.record.backupExcluded, true)

        let reopened = LearningCandidateStore(directory: root.appendingPathComponent("store", isDirectory: true))
        XCTAssertEqual(reopened.candidates, store.candidates)
        reopened.removeAll()
        XCTAssertTrue(LearningCandidateStore(directory: root.appendingPathComponent("store", isDirectory: true))
            .candidates.isEmpty)
    }
}
