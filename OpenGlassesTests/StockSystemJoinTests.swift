import XCTest
@testable import OpenGlasses

/// Plan MM P0 — HF's join across the system's snapshot and the vault's parts table.
final class StockSystemJoinTests: XCTestCase {

    private typealias S = StockSystemSamples

    private let snapshot = S.snapshot([
        S.row("A", part: "ZX-1001", [("L1", "3")]),
        S.row("B", part: "zx-2002", [("L1", "1")]),       // held under the old number
        S.row("C", part: "ZX-3003", [("L1", "2")]),       // in no book
        S.row("D", part: "ZX-5005", [("L1", "4")]),       // the replacement's stock
    ])

    private let book = S.parts([
        ("ZX-1001", "Capacitor 45/5", nil),
        ("ZX-2010", "Contactor, replaces the old one", "ZX-2002"),
        ("ZX-5005", "Relay", "ZX-5000"),
        ("ZX-9009", "Fuse kit", nil),
    ])

    func testTheThreeOutcomesAndNeither() {
        let join = StockSystemJoin(snapshot: snapshot, parts: book)
        guard case .inBoth(let line, let part) = join.join(number: "#zx-1001.") else { return XCTFail("not in both") }
        XCTAssertEqual(line.itemID, "A")
        XCTAssertEqual(part.number, "ZX-1001")

        guard case .vaultOnly(let onlyInBook) = join.join(number: "ZX-9009") else { return XCTFail("not vault only") }
        XCTAssertEqual(onlyInBook.number, "ZX-9009")

        XCTAssertEqual(join.join(number: "ZX-3003"), .systemOnly(snapshot.lines[2], bookSearched: true))
        XCTAssertEqual(join.join(number: "ZX-0000"), .neither)
        XCTAssertEqual(join.join(number: "  "), .neither)
    }

    func testWithNoBookASystemLineWasNotLookedFor() {
        let join = StockSystemJoin(snapshot: snapshot, parts: nil)
        XCTAssertEqual(join.join(number: "ZX-1001"), .systemOnly(snapshot.lines[0], bookSearched: false))
        XCTAssertEqual(join.join(number: "ZX-9009"), .neither)
        // An empty table is no book either.
        let empty = StockSystemJoin(snapshot: snapshot, parts: VaultPartsIndex(files: []))
        XCTAssertEqual(empty.join(number: "ZX-1001"), .systemOnly(snapshot.lines[0], bookSearched: false))
    }

    /// The number on the old part finds the replacement's stock, and the new number finds stock
    /// still held under the old one.
    func testSupersessionResolvesBothWays() {
        let join = StockSystemJoin(snapshot: snapshot, parts: book)
        // Old number asked, replacement stocked.
        XCTAssertEqual(join.join(number: "ZX-5000").line?.itemID, "D")
        // New number asked, stock held under the old number.
        XCTAssertEqual(join.join(number: "ZX-2010").line?.itemID, "B")
        guard case .inBoth(_, let part) = join.join(number: "ZX-2010") else { return XCTFail("not in both") }
        XCTAssertEqual(part.number, "ZX-2010")
    }

    func testAnExactMatchWinsOverASupersededOne() {
        let both = S.snapshot([S.row("OLD", part: "ZX-5000", [("L1", "1")]), S.row("NEW", part: "ZX-5005", [("L1", "4")])])
        let join = StockSystemJoin(snapshot: both, parts: book)
        XCTAssertEqual(join.join(number: "ZX-5005").line?.itemID, "NEW")
    }

    /// Plan MK §4's book order: the open job's vault, else the list's named vault, else none.
    func testMKsBookOrder() {
        let job = S.parts([("ZX-1001", "From the job's vault", nil)])
        let named = S.parts([("ZX-9009", "From the named vault", nil)])
        XCTAssertEqual(StockSystemJoin.book(job: job, named: named), job)
        XCTAssertEqual(StockSystemJoin.book(job: nil, named: named), named)
        XCTAssertEqual(StockSystemJoin.book(job: VaultPartsIndex(files: []), named: named), named)
        XCTAssertNil(StockSystemJoin.book(job: nil, named: nil))
    }
}
