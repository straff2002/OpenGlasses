import XCTest
import PDFKit
import UIKit
@testable import OpenGlasses

/// Plan MN P1 §5: a run through the session service leaves a Plan U record, and the export's JSON
/// and PDF carry a "Procedure record" block built only from what the technician entered and how
/// each route was decided.
@MainActor
final class ProcedureRecordExportTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        tempRoot = F.temporaryRoot("ProcedureRecordExportTests")
        service = FieldSessionService(sessionsRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// pH 4.6 (out of spec, noted) → adjust acid → retest 4.3 → overridden to "high".
    private func runWithAnOverride() throws -> (session: FieldSession, export: SessionExport) {
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Line 3")
        _ = try service.startProcedure(F.phProcedure())
        guard case .needsNote = try service.answerProcedure(value: "4.6", method: .typed,
                                                            locale: Locale(identifier: "en_US")) else {
            throw XCTSkip("expected a note to be owed")
        }
        _ = try service.answerProcedure(value: nil, method: .typed, note: "dosed 2 L acid")
        try service.advanceProcedure(choice: nil)
        try service.advanceProcedure(choice: nil)
        _ = try service.answerProcedure(value: "4.3", method: .typed, locale: Locale(identifier: "en_US"))
        try service.overrideProcedure(branch: "high", reason: "second meter reads 4.6")
        _ = try service.endSession(outcome: .resolved)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: tempRoot.appendingPathComponent(session.id)))
        return (session, export)
    }

    func testTheExportCarriesOneRowPerStepWithTheRouteAndWhy() throws {
        let export = try runWithAnOverride().export
        let record = try XCTUnwrap(export.procedureRecords?.first)
        XCTAssertEqual(record.procedureId, "ph_check")
        XCTAssertEqual(record.title, "pH check")
        XCTAssertEqual(record.rows.map(\.stepId), ["check_ph", "adjust_acid", "check_ph"])
        let first = record.rows[0]
        XCTAssertEqual(first.answerLabel, "pH")
        XCTAssertEqual(first.answer, "4.60")
        XCTAssertEqual(first.entered, "4.6")
        XCTAssertEqual(first.specStatus, "out")
        XCTAssertEqual(first.spec, "3.8 to 4.4")
        XCTAssertEqual(first.note, "dosed 2 L acid")
        XCTAssertEqual(first.method, "typed")
        XCTAssertEqual(first.decidedBy, "rule")
        XCTAssertEqual(first.ruleText, "pH 4.60 is above 4.4")
        XCTAssertEqual(first.nextStepId, "adjust_acid")
        XCTAssertTrue(first.isFlagged)
        XCTAssertNil(record.rows[1].decidedBy, "a linear step records no decision")
        let last = record.rows[2]
        XCTAssertEqual(last.decidedBy, "override")
        XCTAssertEqual(last.ruleBranch, "in_spec")
        XCTAssertEqual(last.reason, "second meter reads 4.6")
        XCTAssertTrue(last.isOverride)
    }

    func testTheRunsAnswersTravelAsACaptureRecord() throws {
        let export = try runWithAnOverride().export
        let capture = try XCTUnwrap(export.captures.first { $0.flowId == "procedure:ph_check@2.1.0" })
        XCTAssertEqual(capture.assetId, "Line 3")
        XCTAssertEqual(capture.fields.map(\.field), ["ph"])
        XCTAssertEqual(capture.fields.first?.value, "4.30", "one field per answer: the retest replaced the first reading")
        XCTAssertEqual(capture.fields.first?.specStatus, "in")
        XCTAssertEqual(capture.fields.first?.stepId, "check_ph")
    }

    func testThePDFPrintsTheBlockAndMarksOverridesAndOutOfSpec() throws {
        let export = try runWithAnOverride().export
        let url = tempRoot.appendingPathComponent("record.pdf")
        try SessionExporter.writePDF(export, to: url)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        XCTAssertTrue(text.contains("Procedure record"))
        XCTAssertTrue(text.contains("OUT OF SPEC"))
        XCTAssertTrue(text.contains("Corrective note: dosed 2 L acid"))
        XCTAssertTrue(text.contains("by rule: pH 4.60 is above 4.4"))
        XCTAssertTrue(text.contains("OVERRIDE"))
        XCTAssertTrue(text.contains("Reason: second meter reads 4.6"))
        XCTAssertFalse(text.contains("Captured Records"), "the procedure's answers print in its own block, not twice")
    }

    func testTheJSONCarriesTheBlockAndAnOlderExportStillDecodes() throws {
        let export = try runWithAnOverride().export
        let url = tempRoot.appendingPathComponent("audit.json")
        try SessionExporter.writeJSON(export, to: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try XCTUnwrap(json["procedure_records"] as? [[String: Any]])
        let rows = try XCTUnwrap(records.first?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["decided_by"] as? String, "rule")
        XCTAssertEqual(rows.first?["spec_status"] as? String, "out")
        var older = json
        older.removeValue(forKey: "procedure_records")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExport.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(decoded.procedureRecords)
    }

    func testAProcedureWithNoAnswersAddsNoBlock() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = try service.startProcedure(id: "low_pressure_diagnostic")
        _ = try service.advanceProcedure(choice: nil)
        _ = try service.endSession(outcome: .resolved)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: tempRoot.appendingPathComponent(session.id)))
        XCTAssertEqual(export.procedureRecords, [])
        XCTAssertFalse(export.captures.contains { $0.flowId.hasPrefix("procedure:") })
    }

    func testAPhotoAnswerListsTheJobPhotosTakenOnTheStep() throws {
        let photo = Procedure(id: "shots", title: "Shots", version: "1", steps: [
            .init(id: "photo", title: "Photograph the bottles", instruction: "Take one.", defaultNext: "end",
                  answer: StepAnswer(recordAs: "bottles", kind: .photo, minPhotos: 1, maxPhotos: 2)),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true),
        ])
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = try service.startProcedure(photo)
        guard case .askAgain = try service.answerProcedure(value: nil, method: .spoken) else {
            return XCTFail("no photo taken yet")
        }
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.5) { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let url = try XCTUnwrap(service.attachPhoto(jpeg, caption: "first bottles"))
        guard case .recorded(let recorded) = try service.answerProcedure(value: nil, method: .spoken) else {
            return XCTFail("the photo taken on the step is attached")
        }
        XCTAssertEqual(recorded.value.photoIds, [url.lastPathComponent])
        XCTAssertEqual(recorded.method, .photo)
        try service.advanceProcedure(choice: nil)
        _ = try service.endSession(outcome: .resolved)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: tempRoot.appendingPathComponent(session.id)))
        XCTAssertEqual(export.procedureRecords?.first?.rows.first?.photoIds, [url.lastPathComponent])
        XCTAssertEqual(export.captures.first { $0.flowId.hasPrefix("procedure:") }?.fields.first?.photoIds, [url.lastPathComponent])
    }
}

/// Plan MN P1 §3: the `procedure_runner` tool's `answer` and `override`, and the confirmation an
/// override needs.
@MainActor
final class ProcedureAnswerToolTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        tempRoot = F.temporaryRoot("ProcedureAnswerToolTests")
        service = FieldSessionService(sessionsRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    func testTheModelAnswersHearsTheReadBackAndCannotChooseAgainstTheRule() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = try service.startProcedure(F.phProcedure())
        let tool = ProcedureRunnerTool(sessionService: service)
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(status.contains("This step takes an answer"), status)
        let heard = try await tool.execute(args: ["action": "answer", "value": "4.3"])
        XCTAssertTrue(heard.contains("\"pH 4.30, in spec, is that right?\""), heard)
        let confirmed = try await tool.execute(args: ["action": "answer", "confirmed": true])
        XCTAssertTrue(confirmed.hasPrefix("Recorded pH: 4.30 (in spec)."), confirmed)
        let refused = try await tool.execute(args: ["action": "next", "choice": "high"])
        XCTAssertTrue(refused.contains("The reading decides: pH 4.30 is between 3.8 and 4.4"), refused)
        let moved = try await tool.execute(args: ["action": "next"])
        XCTAssertTrue(moved.contains("Record the Brix"), moved)
    }

    func testAnOverrideNeedsTheTechniciansReason() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = try service.startProcedure(F.phProcedure())
        _ = try service.answerProcedure(value: "4.3", method: .typed, locale: Locale(identifier: "en_US"))
        let tool = ProcedureRunnerTool(sessionService: service)
        let noReason = try await tool.execute(args: ["action": "override", "branch": "high", "reason": " "])
        XCTAssertTrue(noReason.contains("needs the technician's reason"), noReason)
        let done = try await tool.execute(args: ["action": "override", "branch": "high", "reason": "the meter is off"])
        XCTAssertTrue(done.hasPrefix("Overridden on the technician's word"), done)
        XCTAssertEqual(service.activeProcedureStep?.id, "adjust_acid")
    }

    func testAnOverrideIsAlwaysConfirmedByThePerson() {
        for agentMode in [false, true] {
            let call = ResolvedToolCall.root(name: "procedure_runner",
                                             arguments: ["action": "override", "branch": "high", "reason": "meter off"],
                                             origin: .model)
            guard case .confirm(let summary) = ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: agentMode)) else {
                return XCTFail("agentMode=\(agentMode): an override asks first")
            }
            XCTAssertTrue(summary.contains("Override the procedure's rule and take 'high' because \"meter off\""), summary)
        }
        for action in ["answer", "next", "status"] {
            let call = ResolvedToolCall.root(name: "procedure_runner", arguments: ["action": action], origin: .model)
            XCTAssertEqual(ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: false)), .allow, action)
        }
    }

    func testTheToolDescribesAnswerAndOverride() {
        let tool = ProcedureRunnerTool(sessionService: service)
        XCTAssertTrue(tool.description.contains("'answer'"))
        XCTAssertTrue(tool.description.contains("'override'"))
        XCTAssertTrue(tool.description.contains("you never override a rule on your own"))
        let properties = tool.parametersSchema["properties"] as? [String: Any]
        for key in ["value", "note", "branch", "reason"] { XCTAssertNotNil(properties?[key], key) }
    }
}
