import XCTest
@testable import OpenGlasses

/// Plan GB P0 — the report counts and lists pages from one set, and never prints "..".
final class EvidenceRollupTests: XCTestCase {

    /// Job 1011 as saved: five pages against the job, one (page 30) under a task, one photo.
    private func job1011() -> FieldSession {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let pages = ["SLP99UHVK Installation Instructions, page 17",
                     "SLP99UHVK Installation Instructions, page 64",
                     "SLP99UHVK Installation Instructions, page 65",
                     "SLP99UHVK Service Manual, page 12",
                     "SLP99UHVK Service Manual, page 41"]
        let task = FieldSession.Task(
            id: "t1", title: "Check temperature rise", origin: .operatorAdded, status: .done,
            evidence: FieldSession.Evidence(pagesVerified: ["SLP99UHVK Service Manual, page 30"]),
            completionNote: "Rise within range.", createdAt: started, acceptedAt: started,
            completedAt: started.addingTimeInterval(300))
        return FieldSession(
            id: "s-1011", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly, startedAt: started,
            endedAt: started.addingTimeInterval(4_000), outcome: .resolved, escalations: [],
            billableSeconds: 4_000, jobReference: "1011", tasks: [task],
            jobEvidence: FieldSession.Evidence(photos: ["p1.jpg"], pagesVerified: pages))
    }

    func testJob1011CountsAndListsTheSameSix() {
        let record = WorkRecord(session: job1011(), vaultName: "Lennox SLP99")
        XCTAssertEqual(record.evidenceRollup.verifiedPages.count, 6)
        XCTAssertEqual(record.pagesVerified, record.evidenceRollup.verifiedPages)

        let lines = record.summaryLines
        XCTAssertTrue(lines.contains("Against the job itself: 1 photo."), lines.description)
        XCTAssertFalse(lines.contains { $0.contains("5 pages") }, "no count drawn from a subset")
        let listed = try? XCTUnwrap(lines.first { $0.hasPrefix("Pages verified against") })
        XCTAssertEqual(listed?.components(separatedBy: "; ").count, 6)
    }

    func testAPageOnATaskAndOnTheJobIsListedOnce() {
        let page = "Service Manual, page 30"
        let task = FieldSession.Task(title: "t", origin: .operatorAdded, status: .done,
                                     evidence: .init(pagesVerified: [page]))
        let rollup = EvidenceRollup(tasks: [task], jobEvidence: .init(pagesVerified: [page]))
        XCTAssertEqual(rollup.verifiedPages, [page])
        XCTAssertNil(rollup.jobPhrase, "pages alone say nothing against the job — they are listed")
    }

    func testPunctuatedPiecesJoinWithOneFullStop() {
        let task = FieldSession.Task(
            id: "t", title: "Adjust blower speed", why: "Rise too high for the airflow.",
            origin: .recommended, status: .done, citation: "Service Manual, page 30",
            completionNote: "Rise now within range.")
        let line = WorkRecord.line(for: task)
        XCTAssertEqual(line, "Done: Adjust blower speed. Why: Rise too high for the airflow. "
                       + "Note: Rise now within range. Cited Service Manual, page 30.")
        XCTAssertFalse(line.contains(".."), line)
    }
}
