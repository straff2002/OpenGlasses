import XCTest
@testable import OpenGlasses

/// Tests for SessionExporter: reconstructing the consolidated audit from session.json + log.jsonl,
/// emitting JSON, and rendering a PDF.
@MainActor
final class SessionExporterTests: XCTestCase {

    private var tempRoot: URL!
    private var sessionDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistDeveloperUnlocked")
        VaultRegistry.shared.resetCache()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionExporterTests-\(UUID().uuidString)", isDirectory: true)
        sessionDir = tempRoot.appendingPathComponent("session-1", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "fieldAssistDeveloperUnlocked")
        super.tearDown()
    }

    /// Drive a real session through the service so session.json + log.jsonl are produced naturally.
    private func makePopulatedSession() throws -> FieldSession {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B")
        service.logUserMessage("I see error code E5 on the display")
        service.logAssistantMessage("E5 is a compressor motor lock on Daikin units.", citations: ["error_codes.md"])
        _ = try service.startProcedure(id: "low_pressure_diagnostic")
        _ = try service.advanceProcedure(choice: nil)
        service.recordEscalation(reason: "Readings don't match the manual flowchart")
        _ = try service.endSession(outcome: .escalated)
        // Relocate the produced session dir to the fixed sessionDir path used by the tests.
        let produced = tempRoot.appendingPathComponent(session.id, isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDir)
        try FileManager.default.moveItem(at: produced, to: sessionDir)
        return session
    }

    func testBuildExportReconstructsAuditFields() throws {
        _ = try makePopulatedSession()
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: sessionDir))

        XCTAssertEqual(export.vault, "refrigeration")
        XCTAssertEqual(export.vaultName, "Refrigeration Service")
        XCTAssertEqual(export.assetId, "Unit 47B")
        XCTAssertEqual(export.outcome, "escalated")

        XCTAssertEqual(export.transcript.count, 2)
        XCTAssertEqual(export.transcript.first?.role, "technician")
        XCTAssertTrue(export.transcript.contains { $0.text.contains("E5") })

        XCTAssertTrue(export.citations.contains { $0.source == "error_codes.md" })
        XCTAssertEqual(export.escalations.count, 1)

        let proc = try XCTUnwrap(export.proceduresRun.first { $0.procedureId == "low_pressure_diagnostic" })
        XCTAssertGreaterThanOrEqual(proc.stepsCompleted, 2) // entry + one advance
    }

    func testExportWritesJSONAndPDFFiles() throws {
        _ = try makePopulatedSession()
        let urls = try SessionExporter.export(sessionDir: sessionDir, formats: [.json, .pdf])
        XCTAssertEqual(urls.count, 2)

        let json = sessionDir.appendingPathComponent("audit_export.json")
        let pdf = sessionDir.appendingPathComponent("work_order.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))

        // The PDF should have real content (non-trivial size) and a %PDF header.
        let pdfData = try Data(contentsOf: pdf)
        XCTAssertGreaterThan(pdfData.count, 800)
        XCTAssertEqual(pdfData.prefix(4), Data("%PDF".utf8))

        // The JSON should round-trip back into a SessionExport.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(SessionExport.self, from: Data(contentsOf: json))
        XCTAssertEqual(reloaded.assetId, "Unit 47B")
    }

    func testExportMissingSessionThrows() {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertThrowsError(try SessionExporter.export(sessionDir: missing)) { error in
            guard case SessionExporter.ExportError.sessionNotFound = error else {
                return XCTFail("Expected .sessionNotFound, got \(error)")
            }
        }
    }
}
