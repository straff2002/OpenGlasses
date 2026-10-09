import XCTest
@testable import OpenGlasses

/// Plan FP P1 — a candidate never reaches a prompt as text.
///
/// Not through its store, which no prompt builder reads, and not through the job's transcript:
/// the P0 inventory found that the continuity snapshot renders every technician turn as a
/// "Technician report", so the turn that *said* the finding was the real leak. After a filing, a
/// distinctive marker in the finding must appear in none of the builders a Field Assist turn can
/// see — the vault block, the whole Field Assist context (which carries the snapshot), the debrief
/// block, the live modes' job block, the work record and `field_session` recall — and the snapshot
/// shows the fixed "filed, awaiting review" line in its place.
///
/// The marker is a nonsense word that appears only in the finding and the filing utterance, and
/// absence is asserted on it alone — never on a query word a "no results" message could echo.
@MainActor
final class TeamLearningPromptIsolationTests: XCTestCase {

    /// Shared by no other test and no vault.
    private let marker = "Quillfenwick"

    private var root: URL!
    private var sessions: FieldSessionService!
    private var store: LearningCandidateStore!
    private var tool: TeamLearningTool!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLearningIsolation-\(UUID().uuidString)", isDirectory: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()
        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        store = LearningCandidateStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let service = LearningCandidateService(store: store, sessions: sessions)
        service.authorName = { "Sam Tane" }
        tool = TeamLearningTool(service: service)
    }

    override func tearDown() {
        tool = nil
        store = nil
        sessions = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    private var finding: String { "The \(marker) tubing sweats and reads open on a cold start" }
    private var utterance: String { "Note this for the team, the \(marker) tubing sweats and reads open on a cold start" }

    private func startJob() throws {
        try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "WO-4471")
        sessions.setEquipment(.init(modelToken: "MODEL090", heading: "MODEL090", file: "models.md", source: .spoken))
    }

    private func file() async throws {
        _ = try await tool.execute(args: ["action": "note", "finding": finding, "symptom": "\(marker) lockout"])
        XCTAssertEqual(store.candidates.count, 1, "sanity: the candidate was filed")
        XCTAssertTrue(store.candidates[0].finding.contains(marker), "sanity: the marker is in the candidate")
    }

    /// Everything a Field Assist turn can be shown, after the filing, keyed by where it came from.
    private func everyPromptSurface() async throws -> [String: String] {
        let question = "What is the superheat target on this unit?"
        let vault = try XCTUnwrap(sessions.activeVault)
        let session = try XCTUnwrap(sessions.activeSession)
        let record = try XCTUnwrap(sessions.workRecord())
        let job = DebriefJobResolver.Candidate(sessionId: session.id, jobReference: session.jobReference,
                                               startedAt: session.startedAt, outcomeLabel: "In progress",
                                               isActive: true)
        let recallTool = FieldSessionTool(service: sessions)
        return [
            "VaultPromptBuilder.promptContext": VaultPromptBuilder.promptContext(for: vault, turn: question) ?? "",
            "FieldSessionService.promptContext(turn:)": sessions.promptContext(turn: question) ?? "",
            "FieldSessionService.promptContext() (live modes, no turn)": sessions.promptContext() ?? "",
            "continuity snapshot": sessions.continuityContext() ?? "",
            "DebriefContract.block": DebriefContract.block(job: job, record: record) ?? "",
            "LiveJobContract.block": LiveJobContract.block(session: session) ?? "",
            "field_session recall": try await recallTool.execute(args: ["action": "recall"]),
            "field_session recall (query)": try await recallTool.execute(args: ["action": "recall", "query": "tubing"]),
            "recallContinuity": sessions.recallContinuity(query: nil),
            "WorkRecord read-back": record.summary,
            "WorkRecord JSON": record.jsonString,
        ]
    }

    private func assertNoSurfaceCarriesTheMarker(file: StaticString = #filePath, line: UInt = #line) async throws {
        for (surface, text) in try await everyPromptSurface() {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(marker),
                           "the candidate reached \(surface):\n\(text)", file: file, line: line)
        }
    }

    // MARK: - Direct mode

    /// The wake-word path: `LLMService` logs the turn before the model runs and names it as the
    /// turn in flight, the model calls `team_learning`, and the turn is withheld by its id.
    func testAFiledCandidateReachesNoPromptAndTheSnapshotSaysItWasFiled() async throws {
        try startJob()
        sessions.recordConversationTurn("Supply reads 24 volts at the board", sourceID: "before")

        sessions.turnSourceID = "turn-file"
        sessions.recordConversationTurn(utterance, sourceID: "turn-file")
        XCTAssertTrue(try XCTUnwrap(sessions.continuityContext()).contains(marker),
                      "sanity: before the filing, the utterance is a technician report like any other")
        try await file()
        // A provider that re-records the turn on every tool round finds it already claimed.
        sessions.recordConversationTurn(utterance, sourceID: "turn-file")
        sessions.turnSourceID = nil
        sessions.recordConversationTurn("Now the flame sensor reads 2 microamps", sourceID: "after")

        try await assertNoSurfaceCarriesTheMarker()

        let snapshot = try XCTUnwrap(sessions.continuityContext())
        XCTAssertTrue(snapshot.contains(TeamLearningTurnWithholding.filedLine), snapshot)
        XCTAssertTrue(snapshot.contains("Supply reads 24 volts"), "the turns around it are untouched")
        XCTAssertTrue(snapshot.contains("2 microamps"), "the turns around it are untouched")

        // The log still holds what was said — it is the audit record — and the record knows a
        // candidate exists without knowing what it says.
        let candidate = try XCTUnwrap(store.candidates.first)
        let record = try XCTUnwrap(sessions.workRecord())
        XCTAssertEqual(record.teamLearnings?.map(\.candidateId), [candidate.id])
        XCTAssertTrue(record.jsonString.contains(candidate.id))
    }

    /// A turn the provider logs only after the tool has run — a session started inside the same
    /// turn is the case that does this — is withheld by the same id.
    func testATurnLoggedAfterItsFilingIsWithheldByTheSameId() async throws {
        try startJob()
        sessions.turnSourceID = "turn-late"
        try await file()
        sessions.recordConversationTurn(utterance, sourceID: "turn-late")
        sessions.turnSourceID = nil
        try await assertNoSurfaceCarriesTheMarker()
    }

    /// Amending puts new words in the turn that said them, so that turn is withheld too.
    func testAnAmendmentWithholdsItsTurnToo() async throws {
        try startJob()
        sessions.turnSourceID = "turn-file"
        _ = try await tool.execute(args: ["action": "note", "finding": "The tubing sweats on a cold start"])
        sessions.turnSourceID = "turn-amend"
        sessions.recordConversationTurn("Amend that: the \(marker) tubing sweats, not the hose", sourceID: "turn-amend")
        _ = try await tool.execute(args: ["action": "amend", "finding": "The \(marker) tubing sweats, not the hose"])
        sessions.turnSourceID = nil
        try await assertNoSurfaceCarriesTheMarker()
        XCTAssertTrue(try XCTUnwrap(sessions.continuityContext()).contains(TeamLearningTurnWithholding.amendedLine))
    }

    // MARK: - Tier 0

    /// The phrase route never logs its turn to the job, and its own turn id matches nothing — so a
    /// filing through it hides no neighbouring report.
    func testATierZeroFilingWithholdsNothingElse() async throws {
        try startJob()
        sessions.recordConversationTurn("Supply reads 24 volts at the board", sourceID: "before")
        sessions.turnSourceID = "tier0-\(UUID().uuidString)"
        try await file()
        sessions.turnSourceID = nil
        sessions.recordConversationTurn("Now the flame sensor reads 2 microamps", sourceID: "after")

        try await assertNoSurfaceCarriesTheMarker()
        let snapshot = try XCTUnwrap(sessions.continuityContext())
        XCTAssertTrue(snapshot.contains("Supply reads 24 volts"), snapshot)
        XCTAssertTrue(snapshot.contains("2 microamps"), snapshot)
        XCTAssertTrue(snapshot.contains(TeamLearningTurnWithholding.filedLine), snapshot)
    }

    // MARK: - Live modes

    /// Gemini Live and OpenAI Realtime give a transcript its id when it lands, which can be before
    /// the tool call or after it. A line logged just before the filing is withheld…
    func testALiveTranscriptLoggedJustBeforeTheFilingIsWithheld() async throws {
        try startJob()
        XCTAssertNil(sessions.turnSourceID)
        sessions.recordConversationTurn(utterance, sourceID: "gemini-1-early")
        try await file()
        try await assertNoSurfaceCarriesTheMarker()
    }

    /// …and so is the next one to land within the window after it.
    func testALiveTranscriptThatLandsAfterTheFilingIsWithheld() async throws {
        try startJob()
        try await file()
        sessions.recordConversationTurn(utterance, sourceID: "openai-1-late")
        try await assertNoSurfaceCarriesTheMarker()
        // One line, not every line from then on.
        sessions.recordConversationTurn("The flame sensor reads 2 microamps", sourceID: "openai-1-next")
        XCTAssertTrue(try XCTUnwrap(sessions.continuityContext()).contains("2 microamps"))
    }

    // MARK: - The store is not a prompt source

    /// Even with every turn withheld by hand, the only way the words come back is the author's
    /// own `list`.
    func testOnlyTheAuthorsOwnListReadsTheWordsBack() async throws {
        try startJob()
        sessions.turnSourceID = "tier0-x"
        try await file()
        sessions.turnSourceID = nil
        try await assertNoSurfaceCarriesTheMarker()
        let listed = try await tool.execute(args: ["action": "list"])
        XCTAssertTrue(listed.contains(marker), "list is the one read path, and it is the author's")
    }
}
