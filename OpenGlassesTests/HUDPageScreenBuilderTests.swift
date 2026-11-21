import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0, Plan MU P1 — the page view's lines and button rows (§3), by view: the whole page,
/// the close-up, a spoken zoom, the rows and reading mode. Three buttons at most, Close always
/// last, and none of MG's zoom, move or diagram buttons on any of them.
final class HUDPageScreenBuilderTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)
    private let citation = "Figure 12 · p. 30"

    /// The ids of every button MU took off the lens (the old ones, by their old ids).
    private static let retiredIDs: Set<String> = [
        "kv.page.zoom-in", "kv.page.zoom-out", "kv.page.whole", "kv.page.part", "kv.page.move",
        "kv.page.up", "kv.page.down", "kv.page.left", "kv.page.right", "kv.page.done", "kv.page.next-diagram",
    ]
    private static let retiredLabels: Set<String> = [
        "Zoom in", "Zoom out", "Whole page", "Back to part", "Move", "↑", "↓", "←", "→", "Done", "Next diagram ›",
    ]

    private func whole(firstFrame: Bool = false, nextPage: Bool = false, textHeight: CGFloat = 30) -> HUDPageViewState {
        HUDPageViewState(viewport: LensPageViewport(wholePage: page),
                         legibility: LensLegibility(textHeightPoints: textHeight),
                         isFirstFrame: firstFrame, citation: citation, hasNextPage: nextPage)
    }

    private func ids(_ state: HUDPageViewState) -> [String] {
        HUDPageScreenBuilder.screen(state) { _ in }.items.map(\.id)
    }

    private func rows(highlighted: Int? = 1) -> LensPageRows {
        LensPageRows(title: "Table 3 (Invented codes)", rows: [
            .init(label: "E6", text: "E6 · Fan stalled · Free the fan", headings: "Code · Fault · Action",
                  spoken: "E6. Fault: Fan stalled. Action: Free the fan."),
            .init(label: "E7", text: "E7 · Low supply voltage · Check the supply", headings: "Code · Fault · Action",
                  spoken: "E7. Fault: Low supply voltage. Action: Check the supply."),
        ], highlighted: highlighted)
    }

    private func highlight(words: String?) -> LensPageHighlight {
        LensPageHighlight(reason: .tableRow, rects: [CGRect(x: 60, y: 300, width: 480, height: 14)],
                          part: CGRect(x: 50, y: 290, width: 500, height: 34),
                          legibility: LensLegibility(textHeightPoints: 9), words: words)
    }

    // MARK: - The whole page

    func testTheWholePageIsCloseAloneWithNothingToOffer() {
        let screen = HUDPageScreenBuilder.screen(whole()) { _ in }
        XCTAssertEqual(screen.items.map(\.id), [ID.close])
        XCTAssertEqual(screen.items.map(\.label), ["Close"])
        XCTAssertEqual(screen.items.last?.style, .outline)
        XCTAssertNil(screen.title)
        XCTAssertEqual(whole().view, .whole)
    }

    /// Rows for a table, Read it for words to read, Next page › while another page follows, Close.
    func testTheWholePageRow() {
        var state = whole(nextPage: true)
        XCTAssertEqual(ids(state), [ID.nextPage, ID.close])
        state.rows = rows()
        XCTAssertEqual(ids(state), [ID.rows, ID.nextPage, ID.close])
        XCTAssertEqual(HUDPageScreenBuilder.screen(state) { _ in }.items.map(\.label), ["Rows", "Next page ›", "Close"])
        state.readingPages = readingPages(2)
        XCTAssertEqual(ids(state), [ID.rows, ID.readIt, ID.close], "Next page › gives way first, still said")
        state.rows = nil
        XCTAssertEqual(ids(state), [ID.readIt, ID.nextPage, ID.close])
    }

    func testTheCitationShowsOnTheFirstFrameOnly() {
        let first = HUDPageScreenBuilder.lines(whole(firstFrame: true))
        XCTAssertEqual(first.map(\.text), [citation])
        XCTAssertEqual(first.first?.emphasis, .meta)
        XCTAssertTrue(HUDPageScreenBuilder.lines(whole(firstFrame: false)).isEmpty)
    }

    /// Plan MU §6: the highlighted part's words go under the picture, in the hint's place, and the
    /// frame budgets their lines.
    func testTheWordsReplaceTheHint() throws {
        var state = whole(firstFrame: true, textHeight: 8)
        XCTAssertTrue(state.showsZoomHint, "nothing highlighted, small text: the hint stays")
        XCTAssertEqual(state.pictureBox, LensPageFrame.pictureBox(metaLines: 1, bodyLines: 1))
        state.highlight = highlight(words: "E7 · Low supply voltage · Check the supply")
        XCTAssertFalse(state.showsZoomHint)
        XCTAssertEqual(state.wordsLine, "E7 · Low supply voltage · Check the supply")
        XCTAssertEqual(state.pictureBox, LensPageFrame.pictureBox(metaLines: 1, bodyLines: 2), "two lens lines")
        let picture = HUDPicture(image: LensPageFixtures.picture(), pixelSize: state.pictureBox, contentKey: "p")
        let flow = HUDPageScreenBuilder.wholePageFlow(state, picture: picture) { _ in }
        XCTAssertEqual(flow.count, 2)
        XCTAssertEqual(flow[0].blocks.map(\.id), [ID.wholePicture], "the picture alone in its row")
        XCTAssertEqual(flow[1].lines.map(\.text), ["E7 · Low supply voltage · Check the supply"], "under the picture")
        // Text tall enough to read at the whole page (60 pt draws ~30 px there): no hint, no line.
        let readable = whole(textHeight: 60)
        XCTAssertFalse(readable.showsZoomHint)
        XCTAssertEqual(HUDPageScreenBuilder.wholePageFlow(readable, picture: picture) { _ in }.count, 1)
    }

    func testAPressOnTheWholePageOpensTheCloseUp() throws {
        var pressed: [HUDPageAction] = []
        let picture = HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 576, height: 400), contentKey: "p")
        let flow = HUDPageScreenBuilder.wholePageFlow(whole(), picture: picture) { pressed.append($0) }
        let block = try XCTUnwrap(flow.first?.blocks.first)
        XCTAssertEqual(block.style, .card, "a card, so the lens shows focus on it")
        block.action?()
        XCTAssertEqual(pressed, [.closeUp])
    }

    // MARK: - Close-up, fit width, a spoken zoom, the rows

    func testEveryCloseLookIsBackAndClose() {
        var closeUp = whole()
        closeUp.closeUp = .fitWidth(pageSize: page)
        XCTAssertEqual(closeUp.view, .closeUp)
        XCTAssertEqual(ids(closeUp), [ID.back, ID.close])
        XCTAssertEqual(HUDPageScreenBuilder.screen(closeUp) { _ in }.items.first?.style, .primary, "focus opens on Back")
        XCTAssertTrue(HUDPageScreenBuilder.lines(closeUp).isEmpty)

        var zoomed = whole()
        zoomed.viewport.zoomIn()
        XCTAssertEqual(zoomed.view, .zoomed)
        XCTAssertTrue(zoomed.showsStrip)
        XCTAssertEqual(ids(zoomed), [ID.back, ID.close])

        var table = whole(nextPage: true)
        table.rows = rows()
        table.showsRows = true
        XCTAssertEqual(table.view, .rows)
        XCTAssertEqual(ids(table), [ID.back, ID.close])
        XCTAssertEqual(HUDPageScreenBuilder.lines(table).map(\.text), ["Table 3 (Invented codes)"])
    }

    /// Plan MU §6: the rows view lists the table a card a row, the highlighted one first, with the
    /// column names on each card; a press says the row.
    func testTheRowsAreCardsHighlightedFirst() {
        var state = whole()
        state.rows = rows(highlighted: 1)
        state.showsRows = true
        var pressed: [HUDPageAction] = []
        let screen = HUDPageScreenBuilder.screen(state) { pressed.append($0) }
        let cards = screen.trailingFlow.flatMap(\.blocks)
        XCTAssertEqual(cards.map(\.id), [ID.row(1), ID.row(0)])
        XCTAssertEqual(cards.first?.lines.map(\.text), ["E7 · Low supply voltage · Check the supply", "Code · Fault · Action"])
        XCTAssertEqual(cards.first?.lines.last?.emphasis, .meta)
        XCTAssertTrue(cards.allSatisfy { $0.style == .card })
        cards.forEach { $0.action?() }
        XCTAssertEqual(pressed, [.speakRow(1), .speakRow(0)])
        XCTAssertTrue(screen.flow.isEmpty, "Back and Close at the top, the rows under them")
    }

    func testEveryPressReportsItsAction() {
        var pressed: [HUDPageAction] = []
        let record: (HUDPageAction) -> Void = { pressed.append($0) }
        var state = whole(nextPage: true)
        state.rows = rows()
        HUDPageScreenBuilder.screen(state, onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.rows, .nextPage, .close])

        pressed = []
        state.closeUp = .fitWidth(pageSize: page)
        HUDPageScreenBuilder.screen(state, onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.back, .close])
    }

    func testItemIdsAreStableAndPrefixed() {
        let all = [ID.back, ID.rows, ID.nextPage, ID.close, ID.showHere, ID.nextText,
                   ID.previousText, ID.showPicture, ID.readIt]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.hasPrefix("kv.page.") })
        XCTAssertTrue(Set(all).isDisjoint(with: Self.retiredIDs))
        XCTAssertTrue(ID.wholePicture.hasPrefix("mu.page."))
        XCTAssertNotEqual(ID.row(0), ID.row(1))
    }

    /// Plan MU §3/§6: no page-view row holds more than three buttons, Close is always last, and
    /// none holds Zoom in, Zoom out, Whole page, Move, the arrows, Done, Back to part or Next diagram ›.
    func testNoRowHoldsMoreThanThreeButtonsOrAnOldOne() {
        for zoom in [nil, 1, 2, 4.125] as [CGFloat?] {
            for nextPage in [false, true] {
                for diagrams in [0, 1, 3] {
                    for reading in [false, true] {
                        for table in [false, true] {
                            for view in 0..<3 {
                                var state = HUDPageViewState(viewport: LensPageViewport(pageSize: page, center: CGPoint(x: 306, y: 396),
                                                                                         pixelsPerPoint: zoom),
                                                             legibility: LensLegibility(), hasNextPage: nextPage,
                                                             diagramCount: diagrams, diagramIndex: diagrams > 0 ? 0 : nil)
                                if reading { state.readingPages = readingPages(3) }
                                if table { state.rows = rows() }
                                if view == 1 { state.closeUp = .fitWidth(pageSize: page) }
                                if view == 2, table { state.showsRows = true }
                                let row = HUDPageScreenBuilder.items(state, { _ in })
                                XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons)
                                XCTAssertEqual(row.last?.id, ID.close)
                                XCTAssertTrue(Set(row.map(\.id)).isDisjoint(with: Self.retiredIDs))
                                XCTAssertTrue(Set(row.map(\.label)).isDisjoint(with: Self.retiredLabels))
                            }
                        }
                    }
                }
            }
        }
        for index in 0..<3 {
            for nextPage in [false, true] {
                var state = reading(index, of: 3, nextPage: nextPage)
                state.rows = rows()
                let row = HUDPageScreenBuilder.items(state, { _ in })
                XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons)
                XCTAssertEqual(row.last?.id, ID.close)
            }
        }
    }

    // MARK: - Reading mode

    /// `count` invented reading pages of the reading frame's geometry on the Display.
    private func readingPages(_ count: Int) -> [HUDAnswerPage] {
        let words = (1...(count * 8)).map { "Invented step \($0) of the purge on the board." }.joined(separator: " ")
        let pages = HUDAnswerPager.pages(for: words, geometry: LensPageFrame.readingGeometry, maxPages: count,
                                         firstPageReservedLines: 1)
        XCTAssertEqual(pages.count, count)
        return pages
    }

    private func reading(_ index: Int, of count: Int, nextPage: Bool = false) -> HUDPageViewState {
        var state = whole(nextPage: nextPage)
        state.readingPages = readingPages(count)
        state.readingIndex = index
        state.isReading = true
        return state
    }

    /// Reading mode: Next › while pages remain, Page, ‹ Back after the first page (giving way to
    /// keep three), Next page › on the last, Close.
    func testTheReadingRows() {
        XCTAssertEqual(ids(reading(0, of: 3)), [ID.nextText, ID.showPicture, ID.close])
        XCTAssertEqual(ids(reading(1, of: 3)), [ID.nextText, ID.showPicture, ID.close], "‹ Back gives way; still said")
        XCTAssertEqual(ids(reading(2, of: 3)), [ID.showPicture, ID.previousText, ID.close])
        XCTAssertEqual(ids(reading(2, of: 3, nextPage: true)), [ID.showPicture, ID.nextPage, ID.close])
        let screen = HUDPageScreenBuilder.screen(reading(0, of: 3)) { _ in }
        XCTAssertEqual(screen.items.map(\.label), ["Next ›", "Page", "Close"])

        var pressed: [HUDPageAction] = []
        HUDPageScreenBuilder.screen(reading(2, of: 3)) { pressed.append($0) }.items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.showPicture, .previousText, .close])
    }

    /// The citation over the first reading page only, the page's lines, and its "1/3" footer.
    func testTheReadingLines() {
        let first = HUDPageScreenBuilder.lines(reading(0, of: 3))
        let pages = readingPages(3)
        XCTAssertEqual(first.map(\.text), [citation] + pages[0].lines + ["1/3"])
        XCTAssertEqual(first.first?.emphasis, .meta)
        XCTAssertEqual(first.last?.emphasis, .meta)
        XCTAssertTrue(first.dropFirst().dropLast().allSatisfy { $0.emphasis == .primary })
        let second = HUDPageScreenBuilder.lines(reading(1, of: 3))
        XCTAssertEqual(second.map(\.text), pages[1].lines + ["2/3"], "no citation after the first page")
        XCTAssertFalse(second.contains { $0.text == "Zoom in for labels" })
        XCTAssertLessThanOrEqual(first.count, LensPageFrame.readingGeometry.maxLines)
        XCTAssertLessThanOrEqual(LensPageFrame.height(LensPageFrame.Content(metaLines: 2, bodyLines: first.count - 2)), 600,
                                 "the first page fits the lens")
    }

    /// A close-up's strip: the left half's slices, the "Right half" marker, the right half's.
    func testTheStripMarksTheRightHalf() {
        let picture = HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 576, height: 200), contentKey: "s")
        let flow = HUDPageScreenBuilder.stripSlices([([picture, picture], false), ([picture], true)])
        XCTAssertEqual(flow.count, 4)
        XCTAssertEqual(flow[0].blocks.first?.id, ID.slice(0))
        XCTAssertEqual(flow[1].blocks.first?.id, ID.slice(1))
        XCTAssertEqual(flow[2].lines.map(\.text), ["Right half"])
        XCTAssertEqual(flow[3].blocks.first?.id, ID.slice(2))
        XCTAssertTrue(flow.flatMap(\.blocks).allSatisfy { $0.style == .plain && $0.action == nil && $0.picture != nil })
    }
}
