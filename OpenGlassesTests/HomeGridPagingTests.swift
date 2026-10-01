import XCTest
@testable import OpenGlasses

/// The home grid's pages: how many rows fit, which tile is where, how many dots, and which page the
/// panel lands on when the rows change under it.
///
/// All arithmetic — the grid view draws what `HomeGridPaging` says and nothing else, so this is the
/// layout, checked without a screen.
final class HomeGridPagingTests: XCTestCase {

    private let gap = DockGridMetrics.rowSpacing

    private func ids(_ count: Int) -> [String] { (0..<count).map { "t\($0)" } }

    // MARK: - Rows that fit

    func testRowsThatFitAreWholeRowsBetweenOneAndFour() {
        let row: CGFloat = 80
        let cases: [(height: CGFloat, rows: Int)] = [
            (0, 1), (40, 1), (80, 1), (80 + gap + 79, 1),
            (2 * 80 + gap, 2), (3 * 80 + 2 * gap, 3), (4 * 80 + 3 * gap, 4),
            (1000, 4), (5 * 80 + 4 * gap, 4),
        ]
        for expectation in cases {
            XCTAssertEqual(HomeGridPaging.rowsThatFit(height: expectation.height, rowHeight: row),
                           expectation.rows, "\(expectation.height) pt body")
        }
    }

    /// The whole-row rule: the rows chosen fit the body, and one more would not have — unless the
    /// ceiling or the floor is what stopped it.
    func testNoTileIsEverSliced() {
        for body in stride(from: CGFloat(40), through: 800, by: 7) {
            for row in [CGFloat(80), 92, 104, 130, 160] {
                let rows = HomeGridPaging.rowsThatFit(height: body, rowHeight: row)
                let used = CGFloat(rows) * row + CGFloat(rows - 1) * gap
                let context = "\(body) pt body, \(row) pt row"
                XCTAssertTrue((1...HomeGridPaging.maxRows).contains(rows), context)
                if body >= row {
                    XCTAssertLessThanOrEqual(used, body + 0.001, "A row was sliced: \(context)")
                }
                if rows < HomeGridPaging.maxRows {
                    XCTAssertGreaterThan(used + gap + row, body,
                                         "Another whole row fitted and was not used: \(context)")
                }
            }
        }
    }

    /// Dynamic Type grows the tile, so the same room holds fewer rows — never more.
    func testLargerTextFitsFewerRows() {
        for body in stride(from: CGFloat(100), through: 600, by: 25) {
            var previous = Int.max
            for row in stride(from: CGFloat(80), through: 220, by: 10) {
                let rows = HomeGridPaging.rowsThatFit(height: body, rowHeight: row)
                XCTAssertLessThanOrEqual(rows, previous, "\(body) pt body, \(row) pt row")
                previous = rows
            }
        }
    }

    /// A taller card above leaves less room, so never more rows.
    func testLessRoomNeverAddsARow() {
        for row in [CGFloat(80), 104, 150] {
            var previous = Int.max
            for body in stride(from: CGFloat(600), through: 40, by: -10) {
                let rows = HomeGridPaging.rowsThatFit(height: body, rowHeight: row)
                XCTAssertLessThanOrEqual(rows, previous)
                previous = rows
            }
        }
    }

    // MARK: - One order across the pages

    /// Every tile, once, in order: the pages are consecutive slices of the one order and only the
    /// last can be short.
    func testTilesFlowInOneOrderWithNothingSkippedOrDuplicated() {
        for count in 0...40 {
            for columns in [1, 3] {
                for rows in 1...4 {
                    let paging = HomeGridPaging(tileCount: count, columns: columns, rows: rows)
                    let context = "\(count) tiles, \(columns)×\(rows)"
                    let flowed = (0..<paging.pageCount).flatMap { Array(paging.tileRange(onPage: $0)) }
                    XCTAssertEqual(flowed, Array(0..<count), context)

                    for page in 0..<paging.pageCount where page < paging.pageCount - 1 {
                        XCTAssertEqual(paging.tileRange(onPage: page).count, rows * columns,
                                       "Only the last page may be short: \(context)")
                    }
                    XCTAssertGreaterThanOrEqual(paging.pageCount, 1, context)
                    XCTAssertEqual(paging.dotCount, paging.pageCount + 1, context)
                    if count > 0 {
                        XCTAssertFalse(paging.tileRange(onPage: paging.pageCount - 1).isEmpty,
                                       "An empty trailing page: \(context)")
                    }
                }
            }
        }
    }

    func testPositionsAreRowMajorWithinAPage() {
        let paging = HomeGridPaging(tileCount: 20, columns: 3, rows: 2)
        XCTAssertEqual(paging.tilesPerPage, 6)
        XCTAssertEqual(paging.pageCount, 4)
        XCTAssertEqual(paging.position(ofTile: 0), .init(page: 0, row: 0, column: 0))
        XCTAssertEqual(paging.position(ofTile: 4), .init(page: 0, row: 1, column: 1))
        XCTAssertEqual(paging.position(ofTile: 6), .init(page: 1, row: 0, column: 0))
        XCTAssertEqual(paging.position(ofTile: 19), .init(page: 3, row: 0, column: 1))
        XCTAssertNil(paging.position(ofTile: 20))
        XCTAssertNil(paging.position(ofTile: -1))
        for index in 0..<20 {
            XCTAssertEqual(paging.position(ofTile: index)?.page, paging.page(ofTile: index))
        }
        XCTAssertEqual(paging.rowsDrawn(onPage: 0), 2)
        XCTAssertEqual(paging.rowsDrawn(onPage: 3), 1, "A short last page draws only its rows")
    }

    /// The shipped grid of eighteen at four rows: twelve, then six — and three dots.
    func testTheDefaultGridIsTwoPagesAtFourRows() {
        let paging = HomeGridPaging(tileCount: 18, columns: 3, rows: 4)
        XCTAssertEqual(paging.tileRange(onPage: 0), 0..<12)
        XCTAssertEqual(paging.tileRange(onPage: 1), 12..<18)
        XCTAssertEqual(paging.rowsDrawn(onPage: 1), 2)
        XCTAssertEqual(paging.dotCount, 3)
    }

    func testAnEmptyGridStillHasItsPage() {
        let paging = HomeGridPaging(tileCount: 0, columns: 3, rows: 4)
        XCTAssertEqual(paging.pageCount, 1)
        XCTAssertEqual(paging.dotCount, 2)
        XCTAssertTrue(paging.tileRange(onPage: 0).isEmpty)
        XCTAssertEqual(paging.rowsDrawn(onPage: 0), 0)
    }

    func testRowsAreClampedIntoRange() {
        XCTAssertEqual(HomeGridPaging(tileCount: 5, columns: 3, rows: 0).rows, 1)
        XCTAssertEqual(HomeGridPaging(tileCount: 5, columns: 3, rows: 9).rows, 4)
        XCTAssertEqual(HomeGridPaging(tileCount: 5, columns: 0, rows: 2).columns, 1)
    }

    // MARK: - The pager's indices

    func testTheConversationComesFirstThenTheGridPages() {
        let paging = HomeGridPaging(tileCount: 18, columns: 3, rows: 2)
        XCTAssertEqual(HomeGridPaging.conversationIndex, 0)
        XCTAssertNil(paging.gridPage(forPanelIndex: 0))
        for page in 0..<paging.pageCount {
            let index = paging.panelIndex(forGridPage: page)
            XCTAssertEqual(index, page + 1)
            XCTAssertEqual(paging.gridPage(forPanelIndex: index), page)
        }
        // Out-of-range indices clamp to the grid rather than reading as the conversation.
        XCTAssertEqual(paging.gridPage(forPanelIndex: 99), paging.pageCount - 1)
        XCTAssertEqual(paging.panelIndex(forGridPage: 99), paging.pageCount)
    }

    func testThePanelIndexIsDerivedFromThePagerState() {
        let tiles = ids(18)
        let paging = HomeGridPaging(tileCount: 18, columns: 3, rows: 2)
        XCTAssertEqual(paging.panelIndex(for: DockPagerState(), tileIDs: tiles), 1,
                       "Home is grid page 1")
        XCTAssertEqual(paging.panelIndex(for: DockPagerState(page: .conversation, gridAnchor: "t12"),
                                         tileIDs: tiles), 0)
        XCTAssertEqual(paging.panelIndex(for: DockPagerState(page: .actions, gridAnchor: "t12"),
                                         tileIDs: tiles), 3)
    }

    // MARK: - Reflow keeps the first visible tile

    /// The anchor is the first tile of the page the user chose; whatever the rows become, the panel
    /// shows the page that still holds it.
    func testAReflowLandsOnThePageHoldingTheFirstVisibleTile() {
        let tiles = ids(30)
        for rowsBefore in 1...4 {
            let before = HomeGridPaging(tileCount: 30, columns: 3, rows: rowsBefore)
            for page in 0..<before.pageCount {
                let anchor = before.anchor(forGridPage: page, in: tiles)
                let firstVisible = before.tileRange(onPage: page).lowerBound
                for rowsAfter in 1...4 {
                    let after = HomeGridPaging(tileCount: 30, columns: 3, rows: rowsAfter)
                    let landed = after.gridPage(anchoredAt: anchor, in: tiles)
                    XCTAssertTrue(after.tileRange(onPage: landed).contains(firstVisible),
                                  "Page \(page) at \(rowsBefore) rows lost tile \(firstVisible) "
                                  + "at \(rowsAfter) rows")
                }
            }
        }
    }

    /// The anchor is not rewritten by a reflow, so a card opening and closing again returns to the
    /// page it started on.
    func testACardOpeningAndClosingReturnsToTheSamePage() {
        let tiles = ids(18)
        let open = HomeGridPaging(tileCount: 18, columns: 3, rows: 4)
        let anchor = open.anchor(forGridPage: 1, in: tiles)
        XCTAssertEqual(anchor, "t12")

        let squeezed = HomeGridPaging(tileCount: 18, columns: 3, rows: 2)
        XCTAssertEqual(squeezed.gridPage(anchoredAt: anchor, in: tiles), 2)
        XCTAssertEqual(open.gridPage(anchoredAt: anchor, in: tiles), 1)
    }

    func testTheFirstPageRemembersNoAnchorAndStaysFirst() {
        let tiles = ids(18)
        let paging = HomeGridPaging(tileCount: 18, columns: 3, rows: 4)
        XCTAssertNil(paging.anchor(forGridPage: 0, in: tiles))
        XCTAssertEqual(paging.gridPage(anchoredAt: nil, in: tiles), 0)
    }

    func testAVanishedAnchorFallsBackToAPageThatExists() {
        let tiles = ids(7)
        let paging = HomeGridPaging(tileCount: 7, columns: 3, rows: 1)
        XCTAssertEqual(paging.gridPage(anchoredAt: "gone", in: tiles, fallback: 1), 1)
        XCTAssertEqual(paging.gridPage(anchoredAt: "gone", in: tiles, fallback: 9), 2)
        XCTAssertEqual(paging.gridPage(anchoredAt: "gone", in: tiles, fallback: -3), 0)
    }

    // MARK: - The tiles a page draws

    private let controls = DockLayout.canonical

    private func slots() -> [DockSlot] {
        DockGridCatalog.slots(arrangement: .default, controlOrder: controls,
                              quickActions: [], showsActions: true)
    }

    func testGatedControlsDrawNoTileAndTheOrderIsKept() {
        let all = slots()
        let presence = HomeGridTilePresence(previewAvailable: false, canType: true,
                                            assistiveAvailable: false, connected: false,
                                            localModelActive: false)
        let tiles = presence.tiles(for: all)
        let tileIDs = tiles.map(\.id)

        XCTAssertFalse(tileIDs.contains("control:preview"))
        XCTAssertFalse(tileIDs.contains("control:assistive"))
        XCTAssertFalse(tileIDs.contains("control:disconnect"))
        XCTAssertTrue(tileIDs.contains("control:model"))
        XCTAssertEqual(Set(tileIDs).count, tileIDs.count, "A tile was drawn twice")
        // The survivors keep the arranged order exactly.
        XCTAssertEqual(tileIDs, all.map(\.id).filter { tileIDs.contains($0) })
        // Every action is drawn: gating is a control's, never a content tile's.
        for slot in all where slot.isHideable {
            XCTAssertTrue(tileIDs.contains(slot.id), "\(slot.id) was skipped")
        }
    }

    func testEveryGateOpenDrawsEverySlot() {
        let all = slots()
        let presence = HomeGridTilePresence(previewAvailable: true, canType: true,
                                            assistiveAvailable: true, connected: true,
                                            localModelActive: false)
        XCTAssertEqual(presence.tiles(for: all).map(\.id), all.map(\.id))
    }

    func testTheOnDeviceModelKeyRidesJustInFrontOfModel() {
        let all = slots()
        var presence = HomeGridTilePresence()
        presence.localModelActive = true
        let tileIDs = presence.tiles(for: all).map(\.id)
        guard let model = tileIDs.firstIndex(of: "control:model") else {
            return XCTFail("Model was not drawn")
        }
        XCTAssertGreaterThan(model, 0)
        XCTAssertEqual(tileIDs[model - 1], HomeGridTile.localModelID)
        XCTAssertEqual(tileIDs.filter { $0 == HomeGridTile.localModelID }.count, 1)
    }
}
