import XCTest
@testable import OpenGlasses

/// Lists that redraw on their own (timers, stores) must never show two rows with one id, nor
/// let rows swap places between loads: either asserts in `UICollectionView`'s batch-update
/// validation, which is how build 664 crashed in the background.
final class ListRowIdentityTests: XCTestCase {
    private func session(_ id: String, startedAt: Date) -> FieldSession {
        FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                     startedAt: startedAt, outcome: .resolved, escalations: [], billableSeconds: 0)
    }

    func testJobHistoryKeepsOneSessionPerIdPreferringItsOwnFolder() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var copy = session("s1", startedAt: start)
        copy.jobReference = "copy"
        var own = session("s1", startedAt: start)
        own.jobReference = "own"
        let history = FieldSessionService.historyOrder([
            (folder: "a-copy-of-s1", session: copy),
            (folder: "s1", session: own),
            (folder: "s2", session: session("s2", startedAt: start.addingTimeInterval(60)))
        ])
        XCTAssertEqual(history.map(\.id), ["s2", "s1"])
        XCTAssertEqual(history.last?.jobReference, "own", "the folder named after the id wins")
    }

    func testJobHistoryOrdersSessionsStartedTogetherTheSameWayEveryLoad() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let forward = FieldSessionService.historyOrder([
            (folder: "b", session: session("b", startedAt: start)),
            (folder: "a", session: session("a", startedAt: start))
        ])
        let backward = FieldSessionService.historyOrder([
            (folder: "a", session: session("a", startedAt: start)),
            (folder: "b", session: session("b", startedAt: start))
        ])
        XCTAssertEqual(forward.map(\.id), ["a", "b"])
        XCTAssertEqual(backward.map(\.id), forward.map(\.id))
    }
}
