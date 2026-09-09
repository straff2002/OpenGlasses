import XCTest
@testable import OpenGlasses

/// Tests `SafetyReportPDF` produces a valid, non-empty PDF from a `SafetyReport`. Headless (UIKit PDF
/// rendering works on the simulator).
@MainActor
final class SafetyReportPDFTests: XCTestCase {

    func testGeneratesValidPDFData() throws {
        let report = try SafetyReport.from(json: [
            "summary": "Unshored trench beside a suspended load.",
            "assessments": [
                ["category": "excavation", "is_present": true, "has_indirect_control": true, "indirect_control": "tape"],
                ["category": "suspended_load", "is_present": true, "has_direct_control": true, "direct_control": "rigging"]
            ]
        ])
        let data = SafetyReportPDF.data(for: report)
        XCTAssertGreaterThan(data.count, 500)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))   // valid PDF header
    }

    func testLeaseProducesProtectedFile() throws {
        let report = try SafetyReport.from(json: ["summary": "Clear site.", "assessments": []])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heca-pdf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = StagedExportCoordinator(
            channel: .safetyExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused", root: root))

        let lease = try SafetyReportPDF.makeLease(for: report, coordinator: coordinator)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
        XCTAssertEqual(lease.fileURL.pathExtension, "pdf")
        XCTAssertEqual(lease.displayName, "HECA-\(report.id).pdf")
        // The on-disk name is a UUID; the report id travels only as the display name.
        XCTAssertFalse(lease.fileURL.lastPathComponent.contains(report.id))
        coordinator.release(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }
}
