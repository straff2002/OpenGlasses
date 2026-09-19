import XCTest
@testable import OpenGlasses

@MainActor
final class FieldContinuityTests: XCTestCase {
    private var root: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: root)
    }

    override func tearDown() {
        service = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func equipment(_ model: String) -> EquipmentIdentity {
        .init(modelToken: model, heading: model, file: "models.md", source: .spoken)
    }

    func testLongConversationKeepsExactReportsAndCorrectionsAfterRestore() throws {
        try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.setEquipment(equipment("MODEL070"))
        service.recordConversationTurn("Voltage reading was 240 volts", sourceID: "reading")
        for n in 0..<100 {
            service.recordConversationTurn("Check \(n): " + String(repeating: "observed ", count: 40), sourceID: "turn-\(n)")
        }
        service.recordConversationTurn("Correction: that was 24 volts, not 240", sourceID: "correction")
        service.recordConversationTurn("Correction: that was 24 volts, not 240", sourceID: "correction")
        let context = try XCTUnwrap(service.continuityContext())
        XCTAssertTrue(context.contains("24 volts, not 240"))
        XCTAssertTrue(context.contains("records omitted"))
        XCTAssertLessThan(context.count, 10_000)
        XCTAssertFalse(context.contains("Voltage reading was 240"))
        let oldHistory: [[String: Any]] = (0..<100).flatMap { n in
            [["role": "user", "content": "Question \(n) " + String(repeating: "old context ", count: 100)],
             ["role": "assistant", "content": "Historical answer \(n)"]]
        }
        let selection = try RequestContextBudget.build(model: "test", instructions: service.promptContext() ?? "",
            history: oldHistory + [["role": "user", "content": "What was the corrected reading?"]],
            tools: nil, protectedStart: oldHistory.count, allowance: 100_000)
        XCTAssertGreaterThan(selection.omittedMessages, 0)
        XCTAssertLessThanOrEqual(selection.estimate.total, 100_000)
        let sent = try XCTUnwrap(selection.body["instructions"] as? String)
        XCTAssertTrue(sent.contains("MODEL070"))
        XCTAssertTrue(sent.contains("24 volts, not 240"))

        let restored = FieldSessionService(sessionsRoot: root)
        XCTAssertEqual(restored.activeEquipment?.modelToken, "MODEL070")
        let recalled = restored.recallContinuity(query: "reading", offset: 0)
        XCTAssertTrue(recalled.contains("Voltage reading was 240 volts"))
        XCTAssertTrue(recalled.contains("continuation"))
        let correction = restored.recallContinuity(query: "correction")
        XCTAssertEqual(correction.components(separatedBy: "Correction: that was").count - 1, 1)
    }

    func testTaskStatusAndSafetySurviveSnapshotWithoutInventingCompletion() throws {
        try service.startSession(vaultId: "refrigeration", assetId: nil)
        let proposed = try service.proposeTask(title: "Check supply", safetyNote: "Isolate before touching terminals", citation: "safety.md")
        let completed = try service.addOperatorTask(title: "Check fuse")
        try service.completeTask(id: completed.id, note: "Fuse continuity good")
        service.recordConversationTurn("Should I replace the board?", sourceID: "question")
        let context = try XCTUnwrap(service.continuityContext())
        XCTAssertTrue(context.contains("status=recommended"))
        XCTAssertTrue(context.contains("status=done"))
        XCTAssertTrue(context.contains("Fuse continuity good"))
        XCTAssertTrue(context.contains("Isolate before touching terminals"))
        XCTAssertEqual(service.task(id: proposed.id)?.status, .recommended)
        XCTAssertEqual(service.activeSession?.tasks.count, 2)
    }

    func testEquipmentSwitchScopesWorkAndProcedureAcrossRestart() throws {
        try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.setEquipment(equipment("MODEL070"))
        _ = try service.addOperatorTask(title: "Old machine fuse")
        _ = service.recordIdentityField(name: "Firmware", value: "old-version", source: .spoken)
        XCTAssertTrue(try XCTUnwrap(service.continuityContext()).contains("old-version"))
        service.recordConversationTurn("Old machine reading: 24 volts", sourceID: "old")
        if let procedure = service.availableProcedureDefinitions().first {
            _ = try service.startProcedure(id: procedure.id)
        }
        service.setEquipment(equipment("MODEL090"))
        XCTAssertNil(service.activeTask)
        XCTAssertNil(service.activeProcedureId)
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains("Old machine"))
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains("old-version"))
        XCTAssertFalse(service.recallContinuity(query: nil).contains("24 volts"))
        let restored = FieldSessionService(sessionsRoot: root)
        XCTAssertNil(restored.activeProcedureId)
        XCTAssertNil(restored.activeTask)
        XCTAssertEqual(restored.activeSession?.tasks.count, 1, "Old work remains in the durable job record")
    }

    func testCapturedUnitsAndSessionEndIsolation() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        var record = CaptureRecord(flowId: "meter", sessionId: session.id)
        record.set("supply", value: .number(24, unit: "V"), provenance: .init(method: "voice_number"))
        service.logCaptureRecord(record)
        XCTAssertTrue(try XCTUnwrap(service.continuityContext()).contains("supply=24 V"))
        try service.endSession()
        XCTAssertNil(service.continuityContext())
        try service.startSession(vaultId: "refrigeration", assetId: nil)
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains("24 V"))
    }

    func testOldSessionDecodesAndOversizedReportIsRecoverable() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        for key in ["continuityScope", "taskEquipmentScopes", "identityEquipmentScopes", "procedureEquipmentScope"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(FieldSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.continuityScope, "initial")
        service.recordConversationTurn("Old value: 240 volts", sourceID: "old")
        service.recordConversationTurn(String(repeating: "x", count: 12_000) + " final reading 24 volts", sourceID: "large")
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains("final reading"))
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains("Old value: 240"), "An oversized correction must not leave its old value looking current")
        XCTAssertTrue(service.recallContinuity(query: "large", offset: 8_000).contains("final reading 24 volts"))
    }
}

final class ManualContextBudgetTests: XCTestCase {
    private func passage(_ index: Int, text: String) -> VaultRetriever.Passage {
        .init(documentId: "manual", documentName: "Service Manual", chunkIndex: index, text: text,
              page: 12, section: "Supply", similarity: 0.9, score: 0.9, matchedTokens: ["supply"])
    }

    func testCompletePassagesRetainUnitsAndCitationsAndStateOmissions() {
        let evidence = passage(0, text: "Supply | Volts\nControl | 24 V\nIsolate before inspection.")
        let huge = passage(1, text: String(repeating: "Oversized other section ", count: 1_000))
        let block = VaultRetriever.promptBlock(.sufficient([evidence, huge, evidence]), characterLimit: 1_000)
        XCTAssertTrue(block.contains(evidence.text))
        XCTAssertTrue(block.contains("Source: Service Manual, page 12"))
        XCTAssertFalse(block.contains("Oversized other section"))
        XCTAssertTrue(block.contains("2 manual passages omitted"))
        let tool = VaultRetriever.toolResult(.sufficient([huge]), query: "supply")
        XCTAssertTrue(tool.contains("could not fit as complete passages"))
        XCTAssertFalse(tool.contains("Oversized other section"))
    }

    func testCoreBudgetKeepsSafetyAndRulesAndReferencesOmittedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = VaultManifest(id: "budget", name: "Budget", version: "1", files: ["reference.md", "safety.md"], promptRules: ["Never guess."])
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: root)
        try store.write("reference.md", contents: String(repeating: "Reference detail ", count: 1_000))
        try store.write("safety.md", contents: "Isolate power before touching terminals.")
        let prompt = try XCTUnwrap(VaultPromptBuilder.promptContext(for: store, referenceByteLimit: 100))
        XCTAssertTrue(prompt.contains("Never guess."))
        XCTAssertTrue(prompt.contains("Isolate power before touching terminals."))
        XCTAssertTrue(prompt.contains("references omitted by the context budget: reference.md"))
        XCTAssertFalse(prompt.contains("Reference detail"))
        XCTAssertTrue(try XCTUnwrap(store.read("reference.md")).contains("Reference detail"))
    }
}
