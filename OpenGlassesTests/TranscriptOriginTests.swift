import XCTest
@testable import OpenGlasses

/// Plan GB P0 — the job's transcript is the whole exchange, both sides, and never the app's own
/// kickoff instruction under the technician's name.
@MainActor
final class TranscriptOriginTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptOriginTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private var kickoff: String { QuickAction.fieldAssist.promptText ?? "" }

    // MARK: - The classifier

    func testOnlyTheAppsOwnPromptsWordForWordAreAppInstructions() {
        XCTAssertEqual(TranscriptOriginClassifier.origin(of: kickoff), .appInstruction)
        XCTAssertEqual(TranscriptOriginClassifier.origin(of: "  " + kickoff + "\n"), .appInstruction,
                       "whitespace at the ends is ignored")
        XCTAssertEqual(TranscriptOriginClassifier.origin(
            of: "Start a Field Assist session on my default vault. Briefly confirm you're ready and what you can help me troubleshoot."),
                       .appInstruction, "the pre-FO wording is still recognised in old records")
        // Anything else is the technician, however instruction-like.
        XCTAssertEqual(TranscriptOriginClassifier.origin(of: "Start a Field Assist session"), .technician)
        XCTAssertEqual(TranscriptOriginClassifier.origin(of: kickoff.lowercased()), .technician)
        XCTAssertEqual(TranscriptOriginClassifier.origin(of: "supply air is 140"), .technician)
    }

    // MARK: - A fresh record

    private func runJob(tagKickoff: Bool) throws -> URL {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        if tagKickoff { service.expectAppInstruction(kickoff) }
        service.recordConversationTurn(kickoff, sourceID: "turn-0")
        service.recordAssistantReply("Ready. What are you working on?", sourceID: "turn-0")
        service.recordConversationTurn("Supply air is 140", sourceID: "turn-1")
        service.recordAssistantReply("That is high.\nSource: Service Manual, page 30", sourceID: "turn-1")
        // A retried turn does not log its answer twice.
        service.recordAssistantReply("That is high.\nSource: Service Manual, page 30", sourceID: "turn-1")
        _ = try service.endSession()
        return tempRoot.appendingPathComponent(session.id, isDirectory: true)
    }

    func testTheKickoffIsLoggedAsAnAppInstructionAndKeptOutOfTheTranscript() throws {
        let dir = try runJob(tagKickoff: true)
        let events = SessionLogger.readEvents(at: dir)
        XCTAssertEqual(events.filter { $0.kind == .appInstruction }.count, 1, "it happened, so it is logged")
        XCTAssertFalse(events.contains { $0.kind == .userMessage && $0.text == kickoff })

        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertFalse(export.transcript.contains { $0.text == kickoff })
        XCTAssertEqual(export.transcript.map(\.role), ["assistant", "technician", "assistant"])
    }

    func testAnswersArePresentAndTheirSourcesBecomeCitations() throws {
        let dir = try runJob(tagKickoff: true)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertEqual(export.transcript.filter { $0.role == "assistant" }.count, 2,
                       "both answers, once each")
        XCTAssertEqual(export.citations.map(\.source), ["Service Manual, page 30"])
    }

    func testALegacyRecordWithTheKickoffAsAUserMessageExportsWithoutIt() throws {
        // Saved before the origin was tagged: the kickoff sits in the log as a user message.
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let dir = tempRoot.appendingPathComponent(session.id, isDirectory: true)
        let legacyLogger = SessionLogger(session: session, root: dir)
        legacyLogger.appendUserMessage(kickoff)
        legacyLogger.appendUserMessage("Supply air is 140")
        _ = try service.endSession()

        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertEqual(export.transcript.map(\.text), ["Supply air is 140"])

        let job = JobTranscriptExport.job(session: try XCTUnwrap(service.history.first),
                                          vaultName: "Refrigeration", thread: nil,
                                          events: SessionLogger.readEvents(at: dir))
        XCTAssertEqual(job.lines.map(\.text), ["Supply air is 140"])
    }

    func testTheContinuitySnapshotDoesNotReportTheKickoffAsTheTechnicians() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.recordConversationTurn(kickoff, sourceID: "turn-0")
        service.recordConversationTurn("Supply air is 140", sourceID: "turn-1")
        let recall = service.recallContinuity(query: nil)
        XCTAssertFalse(recall.contains("do not call field_session start"), recall)
        XCTAssertTrue(recall.contains("Supply air is 140"), recall)
    }
}
