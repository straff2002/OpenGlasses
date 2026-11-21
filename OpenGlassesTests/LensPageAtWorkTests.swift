#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan MU P1 — a page you get around in one or two moves. Headless: the rows of an invented
/// table (`LensPageRows`), the highlight and its words (`LensPageHighlight`), the close-up and fit
/// width (`LensPageCloseUp`), the dimmed whole page (`LensPageRenderPlan`, and an invented PDF drawn
/// for real), and the page view wired through the display's seams: a cited row outlined with its
/// words under the picture and no press; the close-up of the highlight wherever the lens is; any
/// cell one press away; Rows, a pressed row said aloud, "show E9"; pages with no table, no mark and
/// no figure; never two pictures in a row and never Move, an arrow or Done on any lens screen.
///
/// Every table, code and word here is invented.
@MainActor
final class LensPageAtWorkTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID
    private let letter = LensPageFixtures.letter

    // MARK: - An invented table

    /// "Table 3 (Kwartz fault codes)" on page 3: three rows, a heading column and two value columns.
    private static func faultTable(uncertainRow: Bool = false) -> ManualTable {
        let page = ManualTable.Page(physical: 3, printed: "3")
        let rows = [
            ManualTable.Row(path: ["E6"], cells: [.init(text: "Fan stalled"), .init(text: "Free the fan")], page: page),
            ManualTable.Row(path: ["E7"], cells: [.init(text: "Low supply voltage"), .init(text: "Check the supply")], page: page),
            ManualTable.Row(path: ["E9"], cells: [.init(text: "Sensor open", uncertain: uncertainRow),
                                                  .init(text: "Reseat the sensor")], page: page,
                            keyUncertain: false),
            ManualTable.Row(path: ["E12"], cells: [.init(text: "Elsewhere"), .init(text: "Not on this page")],
                            page: ManualTable.Page(physical: 4)),
        ]
        return ManualTable(label: "Table 3", title: "Kwartz fault codes", page: page, rowHeaders: ["Code"],
                           columns: [.init(path: ["Fault"]), .init(path: ["Action"])], rows: rows)
    }

    /// The row passage an answer cites for `row`, as the store wrote it.
    private static func citedRow(_ index: Int, in table: ManualTable) -> CitedPassage {
        let text = TableRowPassage.sentence(for: table.rows[index], in: table) ?? ""
        return CitedPassage(number: 1, anchor: PassageAnchor(documentId: "doc-invented", chunkIndex: 40 + index,
                                                             text: text, page: 3,
                                                             printedRuns: TableRowPassage.printedRuns(of: table.rows[index])))
    }

    func testTheRowsOfAnInventedTable() throws {
        let table = Self.faultTable()
        let rows = try XCTUnwrap(LensPageRows.make(tables: [table], page: 3, cited: [Self.citedRow(1, in: table)]))
        XCTAssertEqual(rows.title, "Table 3 (Kwartz fault codes)")
        XCTAssertEqual(rows.rows.map(\.text), ["E6 · Fan stalled · Free the fan",
                                               "E7 · Low supply voltage · Check the supply",
                                               "E9 · Sensor open · Reseat the sensor"], "this page's rows only")
        XCTAssertEqual(rows.rows[1].headings, "Code · Fault · Action", "the column names on each card")
        XCTAssertEqual(rows.rows[1].spoken, "E7. Fault: Low supply voltage. Action: Check the supply.")
        XCTAssertEqual(rows.highlighted, 1, "the cited row")
        XCTAssertEqual(rows.order, [1, 0, 2], "opened at the cited row")
        XCTAssertEqual(rows.highlightedText, "E7 · Low supply voltage · Check the supply")
        XCTAssertEqual(rows.index(matching: "e 7"), 1)
        XCTAssertEqual(rows.index(matching: "E-9"), 2)
        XCTAssertNil(rows.index(matching: "E12"), "on another page")
        XCTAssertNil(LensPageRows.make(tables: [table], page: 3)?.highlighted, "nothing cited, nothing highlighted")
    }

    func testRowsShowNothingReadUnclearlyAndNoTableIsNoRows() throws {
        let unclear = try XCTUnwrap(LensPageRows.make(tables: [Self.faultTable(uncertainRow: true)], page: 3))
        XCTAssertEqual(unclear.rows[2].text, "E9 · Reseat the sensor", "the uncertain cell left out")
        XCTAssertNil(LensPageRows.make(tables: [], page: 3), "no table: no Rows")
        XCTAssertNil(LensPageRows.make(tables: [Self.faultTable()], page: 9), "no table printed on this page")
        var withheld = Self.faultTable()
        withheld.uncheckedWithheld = true
        XCTAssertNil(LensPageRows.make(tables: [withheld], page: 3), "a table that must be checked first offers no rows")
        let failed = ManualTable(label: "Table 4", title: "", page: .init(physical: 3), columns: [], rows: [],
                                 failure: .tooFewRows)
        XCTAssertNil(LensPageRows.make(tables: [failed], page: 3))
    }

    // MARK: - The highlight and its words

    /// A cited row is outlined and its words are under the picture, with no press.
    func testACitedRowIsOutlinedAndItsWordsAreUnderThePicture() throws {
        let table = Self.faultTable()
        let row = CGRect(x: 72, y: 340, width: 470, height: 12)
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [row], bounds: row)], showsNumbers: false)
        let layout = LensPageLayout(pageSize: letter, marks: marks, pictureAreas: [], tone: .lineArt)
        let cited = [Self.citedRow(1, in: table)]
        let rows = LensPageRows.make(tables: [table], page: 3, cited: cited)
        let highlight = LensPageHighlight.of(layout, cited: cited, page: 3, rows: rows)
        XCTAssertEqual(highlight.reason, .tableRow)
        XCTAssertEqual(highlight.rects, [row])
        XCTAssertEqual(highlight.words, "E7 · Low supply voltage · Check the supply")
        XCTAssertEqual(highlight.wordsLineCount, 2)

        var staged = LensPageFixtures.staged(figure: "Table 3")
        staged.citedPassages = cited
        let page = LensPageSession.Page(staged: staged, source: URL(fileURLWithPath: "/invented/guide.pdf"),
                                        identity: LensPageSession.identity(of: staged))
        let opening = LensPageSession.openingState(layout, page: page, hasNextPage: false, rows: rows)
        XCTAssertEqual(opening.view, .whole, "no press")
        XCTAssertEqual(opening.wordsLine, "E7 · Low supply voltage · Check the supply")
        XCTAssertEqual(HUDPageScreenBuilder.items(opening, { _ in }).map(\.id), [ID.rows, ID.close])
        let plan = try XCTUnwrap(LensPageSession.renderPlans(opening, layout: layout).first)
        XCTAssertEqual(plan.marks.count, 1, "the row outlined")
        XCTAssertNotNil(plan.brightRects, "the rest of the page dimmed")
        XCTAssertTrue(try XCTUnwrap(plan.brightRects?.first).contains(plan.marks[0].rect))

        // Without the vault's table, the row passage's own values.
        let bare = LensPageHighlight.of(layout, cited: cited, page: 3, rows: nil)
        XCTAssertEqual(bare.words, "E7 · Low supply voltage · Check the supply")
    }

    func testAPassagesFirstSentenceAndAPageWithNothingToHighlight() {
        let line = CGRect(x: 72, y: 200, width: 400, height: 11)
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [line], bounds: line)], showsNumbers: false)
        let reading = LensPageReading(passages: [.init(number: 1, words: "Purge the invented line first. Then close the cap.")],
                                      showsNumbers: false)
        let passage = LensPageLayout(pageSize: letter, marks: marks, pictureAreas: [], tone: .lineArt, reading: reading)
        let anchor = PassageAnchor(documentId: "doc-invented", chunkIndex: 2, text: "Purge the invented line first.", page: 3)
        let highlight = LensPageHighlight.of(passage, cited: [CitedPassage(number: 1, anchor: anchor)], page: 3, rows: nil)
        XCTAssertEqual(highlight.reason, .citedMark)
        XCTAssertEqual(highlight.words, "Purge the invented line first.")
        XCTAssertEqual(highlight.wordsLineCount, 1)

        // No table, no mark, no figure: nothing highlighted, nothing dimmed, no words.
        let plain = LensPageLayout(pageSize: letter, marks: nil, pictureAreas: [], tone: .lineArt)
        let none = LensPageHighlight.of(plain, cited: [], page: 3, rows: nil)
        XCTAssertEqual(none.reason, .none)
        XCTAssertNil(none.part)
        XCTAssertNil(none.words)
        let state = HUDPageViewState(viewport: plain.openingViewport, legibility: plain.legibility, highlight: none)
        XCTAssertNil(LensPageSession.renderPlans(state, layout: plain).first?.brightRects)
        XCTAssertEqual(LensPageSession.closeUpState(state).closeUp?.kind, .fitWidth, "a pinch opens fit width")
    }

    // MARK: - The close-up

    func testAWidePartIsCutIntoHalvesThatTogetherHoldIt() {
        let row = CGRect(x: 40, y: 340, width: 532, height: 30)
        let closeUp = LensPageCloseUp.of(part: row, pageSize: letter, legibility: LensLegibility(textHeightPoints: 9),
                                         wholePagePixelsPerPoint: LensPageViewport.fitPixelsPerPoint(pageSize: letter, box: LensPageViewport.plainBox))
        XCTAssertTrue(closeUp.hasHalves)
        XCTAssertEqual(closeUp.columns.count, 2)
        XCTAssertLessThanOrEqual(closeUp.columns[0].minX, row.minX + 0.01)
        XCTAssertGreaterThanOrEqual(closeUp.columns[1].maxX, row.maxX - 0.01)
        XCTAssertGreaterThanOrEqual(closeUp.columns[0].maxX + 0.01, closeUp.columns[1].minX, "the halves meet: no cell between them")
        XCTAssertEqual(closeUp.columns[0].minY, row.minY, accuracy: 0.01, "both start at the part's top")
        XCTAssertTrue(closeUp.columns.allSatisfy { $0.maxY > row.maxY }, "and run on down the page past it")
        let total = closeUp.columns.map { closeUp.outputSize(of: $0).height }.reduce(0, +)
        XCTAssertLessThanOrEqual(total, LensPageStrip.maxHeightPixels + 2, "within the send budget")
        XCTAssertTrue(closeUp.columns.allSatisfy { closeUp.outputSize(of: $0).width == LensPageFrame.contentWidthPixels })
        XCTAssertGreaterThanOrEqual(closeUp.pixelsPerPoint * 9, 18, "readable: 9 pt text near the lens's floor")
        XCTAssertEqual(closeUp.shownColumns.map { $0.isRightHalf }, [false, true])
        var right = closeUp
        right.only = .right
        XCTAssertEqual(right.shownColumns.map { $0.rect }, [closeUp.columns[1]])
    }

    func testANarrowPartIsOneColumnAndATallOneIsWhole() {
        let fit = LensPageViewport.fitPixelsPerPoint(pageSize: letter, box: LensPageViewport.plainBox)
        let small = CGRect(x: 250, y: 300, width: 120, height: 40)
        let one = LensPageCloseUp.of(part: small, pageSize: letter, legibility: LensLegibility(textHeightPoints: 9),
                                     wholePagePixelsPerPoint: fit)
        XCTAssertFalse(one.hasHalves)
        XCTAssertTrue(one.columns[0].insetBy(dx: -0.01, dy: -0.01).contains(small))
        XCTAssertGreaterThanOrEqual(one.pixelsPerPoint, 2 * fit, "at least twice the whole page")

        let tall = CGRect(x: 100, y: 50, width: 300, height: 700)
        let whole = LensPageCloseUp.of(part: tall, pageSize: letter, legibility: LensLegibility(textHeightPoints: 8),
                                       wholePagePixelsPerPoint: fit)
        let covered = whole.columns.reduce(whole.columns[0]) { $0.union($1) }
        XCTAssertTrue(covered.insetBy(dx: -0.5, dy: -0.5).contains(tall), "the whole part is always there")
    }

    func testFitWidthIsThePageAsWideAsTheLens() {
        let fit = LensPageCloseUp.fitWidth(pageSize: letter)
        XCTAssertEqual(fit.columns.count, 1)
        XCTAssertEqual(fit.columns[0], CGRect(origin: .zero, size: letter), "a letter page fits the budget whole")
        XCTAssertEqual(fit.outputSize(of: fit.columns[0]).width, 576)
        let tallPage = CGSize(width: 612, height: 1600)
        let top = LensPageCloseUp.fitWidth(pageSize: tallPage)
        let bottom = LensPageCloseUp.fitWidth(pageSize: tallPage, fromBottom: true)
        XCTAssertEqual(top.columns[0].minY, 0)
        XCTAssertEqual(bottom.columns[0].maxY, 1600, accuracy: 0.01, "go to the bottom: ending at the page's foot")
        XCTAssertLessThanOrEqual(bottom.outputSize(of: bottom.columns[0]).height, LensPageStrip.maxHeightPixels + 1)
    }

    // MARK: - Wired

    @MainActor
    private final class Spoken { var lines: [String] = [] }

    private struct Rig {
        let display: GlassesDisplayService
        let router: HUDRouter
        let session: LensPageSession
        let spoken: Spoken
    }

    private var savedDisplayEnabled = false
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.setGlassesDisplayEnabled(true)
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        try await super.tearDown()
    }

    /// A row of the invented table, as the page's text layer would mark it.
    private static let rowRect = CGRect(x: 60, y: 340, width: 492, height: 12)

    private func makeRig(cited: Bool = true, table: Bool = true, marks: Bool = true) -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        let spoken = Spoken()
        session.sourceURL = { _ in URL(fileURLWithPath: "/invented/guide.pdf") }
        session.requestWords = { "what does E7 mean" }
        let letter = self.letter
        session.layoutPage = { _ in
            let found = marks
                ? LensPageMarks(marks: [.init(number: 1, lineRects: [Self.rowRect], bounds: Self.rowRect)], showsNumbers: false)
                : nil
            return LensPageLayout(pageSize: letter, marks: found, pictureAreas: [], tone: .lineArt)
        }
        session.pageTables = { _ in table ? [Self.faultTable()] : [] }
        session.speak = { spoken.lines.append($0) }
        session.renderPicture = { _, _ in LensPageFixtures.picture() }
        session.scheduleTimer = { _, _ in }
        session.backend = { "metaRayBan" }
        session.pictureFactor = { 1 }
        return Rig(display: display, router: router, session: session, spoken: spoken)
    }

    private func staged(cited: Bool = true) -> FieldSessionService.StagedFigure {
        var staged = LensPageFixtures.staged(figure: "Table 3")
        if cited { staged.citedPassages = [Self.citedRow(1, in: Self.faultTable())] }
        return staged
    }

    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    private func press(_ rig: Rig, _ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let screen = rig.session.shownScreen else { return XCTFail("nothing on the lens", file: file, line: line) }
        if let index = screen.items.firstIndex(where: { $0.id == id }) {
            rig.display.testInteractiveButtonActions(for: screen)[index]()
        } else if let index = screen.allBlocks.firstIndex(where: { $0.id == id }) {
            rig.display.testInteractiveBlockActions(for: screen)[index]()
        } else {
            return XCTFail("no \(id) on the lens", file: file, line: line)
        }
        await drain(rig)
    }

    /// The cited row opens whole, outlined, its words under the picture; one press reads it closely;
    /// Back; Rows opens at the row; a pressed row is said; "show E9" goes to that row.
    func testACitedTableRowFromOpeningToRows() async throws {
        let rig = makeRig()
        rig.session.stage([staged()])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(opening.view, .whole)
        XCTAssertEqual(opening.highlight.reason, .tableRow)
        let screen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertEqual(screen.flow.last?.lines.map(\.text), ["E7 · Low supply voltage · Check the supply"],
                       "the row's words under the picture, no press")
        XCTAssertEqual(screen.items.map(\.id), [ID.rows, ID.close])
        XCTAssertTrue(screen.focusesFirstBlock, "focus opens on the picture")

        await press(rig, ID.wholePicture)
        let closeUp = try XCTUnwrap(rig.session.shownState?.closeUp)
        XCTAssertEqual(closeUp.kind, .part)
        let covered = closeUp.columns.reduce(closeUp.columns[0]) { $0.union($1) }
        XCTAssertTrue(covered.insetBy(dx: -0.5, dy: -0.5).contains(Self.rowRect), "the close-up is of the row")
        XCTAssertTrue(closeUp.hasHalves, "a row as wide as the page: both halves, stacked")

        await press(rig, ID.back)
        await press(rig, ID.rows)
        let rows = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertEqual(rig.session.shownState?.view, .rows)
        XCTAssertEqual(rows.items.map(\.id), [ID.back, ID.close])
        XCTAssertEqual(rows.trailingFlow.first?.blocks.first?.id, ID.row(1), "opened at the highlighted row")
        await press(rig, ID.row(1))
        XCTAssertEqual(rig.spoken.lines, ["E7. Fault: Low supply voltage. Action: Check the supply."])

        let showE9 = await rig.router.handleVoiceCommand("show E9")
        await drain(rig)
        XCTAssertTrue(showE9)
        XCTAssertEqual(rig.session.shownScreen?.trailingFlow.first?.blocks.first?.id, ID.row(2))
        let showNothing = await rig.router.handleVoiceCommand("show Q99")
        XCTAssertFalse(showNothing, "no such row: the words go on")

        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.closeUps, 1)
        XCTAssertEqual(stats.rowsViews, 2)
        XCTAssertEqual(stats.rowsSpoken, 1)
        XCTAssertEqual(stats.highlights, ["table_row": 1])
    }

    /// The close-up is of the highlight wherever the lens is: from a spoken zoom off in a corner,
    /// "close-up" goes to the highlighted row, not to what was in view.
    func testTheCloseUpIsOfTheHighlightWhereverTheLensIs() async throws {
        let rig = makeRig()
        rig.session.stage([staged()])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomInto(.topLeft)))
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomIn))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .zoomed)
        XCTAssertFalse(try XCTUnwrap(rig.session.shownState).viewport.cropRect.intersects(Self.rowRect), "away from the row")
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        let closeUp = try XCTUnwrap(rig.session.shownState?.closeUp)
        let covered = closeUp.columns.reduce(closeUp.columns[0]) { $0.union($1) }
        XCTAssertTrue(covered.insetBy(dx: -0.5, dy: -0.5).contains(Self.rowRect))
        XCTAssertTrue(rig.session.handle(.half(.right)))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.closeUp?.only, .right)
        XCTAssertFalse(try XCTUnwrap(rig.session.shownScreen).trailingFlow.isEmpty)
    }

    /// Any cell is reached by scrolling plus at most one press: every cell of the page's table is on
    /// the Rows view (one press), and on a page with nothing highlighted fit width (one press) holds
    /// the whole page.
    func testAnyCellIsOnePressAway() async throws {
        let rig = makeRig()
        rig.session.stage([staged()])
        await drain(rig)
        await press(rig, ID.rows)
        let texts = try XCTUnwrap(rig.session.shownScreen).trailingFlow.flatMap(\.lines).map(\.text)
        let table = Self.faultTable()
        for row in table.rows where row.page.physical == 3 {
            for cell in row.cells { XCTAssertTrue(texts.contains { $0.contains(cell.text) }, cell.text) }
        }

        let plain = makeRig(cited: false, table: false, marks: false)
        plain.session.stage([staged(cited: false)])
        await drain(plain)
        XCTAssertEqual(plain.session.shownState?.highlight.reason, LensPageHighlight.Reason.none)
        XCTAssertEqual(plain.session.shownScreen?.items.map(\.id), [ID.close], "no table, no Rows")
        await press(plain, ID.wholePicture)
        let fit = try XCTUnwrap(plain.session.shownState?.closeUp)
        XCTAssertEqual(fit.kind, .fitWidth)
        XCTAssertEqual(fit.columns[0], CGRect(origin: .zero, size: letter), "the whole page, scrolled from the top")
        await press(plain, ID.back)
        XCTAssertTrue(plain.session.handle(.bottom))
        await drain(plain)
        XCTAssertEqual(plain.session.shownState?.closeUp?.columns.first?.maxY ?? 0, letter.height, accuracy: 0.01)
    }

    /// Every screen the page view puts on the lens — whole, close-up, halves, fit width, a spoken
    /// zoom, rows, reading — has at most three buttons, Close last, no Move, arrow or Done, and never
    /// two pictures side by side.
    func testNoLensScreenHasTwoPicturesInARowOrAnOldButton() async throws {
        let retired: Set<String> = ["Zoom in", "Zoom out", "Whole page", "Back to part", "Move", "↑", "↓", "←", "→",
                                    "Done", "Next diagram ›"]
        var screens: [HUDScreen] = []
        let rig = makeRig()
        rig.session.stage([staged()])
        await drain(rig)
        func keep() { if let shown = rig.session.shownScreen { screens.append(shown) } }
        keep()
        await press(rig, ID.wholePicture); keep()
        XCTAssertTrue(rig.session.handle(.half(.left))); await drain(rig); keep()
        XCTAssertTrue(rig.session.handle(.bottom)); await drain(rig); keep()
        XCTAssertTrue(rig.session.handle(.zoomInto(.bottomRight))); await drain(rig); keep()
        XCTAssertTrue(rig.session.handle(.move(.left))); await drain(rig); keep()
        await press(rig, ID.back); keep()
        await press(rig, ID.rows); keep()
        XCTAssertGreaterThanOrEqual(screens.count, 8)
        screens.append(LensFitCheck.screen {})
        for screen in screens {
            XCTAssertFalse(screen.hasPicturesSideBySide, screen.renderKey)
            XCTAssertLessThanOrEqual(screen.items.count, 3)
            XCTAssertTrue(Set(screen.items.map(\.label)).isDisjoint(with: retired), "\(screen.items.map(\.label))")
            XCTAssertTrue(HUDExit.hasExit(screen))
        }
    }

    // MARK: - The dimmed page, drawn

    func testTheWholePageIsDimmedAroundTheHighlight() throws {
        let url = try LensPageFixtures.pdf(paper: .white, ink: .black)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let box = LensPageViewport.plainBox
        let viewport = LensPageViewport(wholePage: letter, box: box)
        let layout = LensPageLayout(pageSize: letter, marks: nil, pictureAreas: [], tone: .lineArt)
        let lit = LensPageRenderPlan(layout: layout, viewport: viewport, highlight: [LensPageFixtures.inkBlock])
        let plain = LensPageRenderPlan(layout: layout, viewport: viewport)
        XCTAssertNil(plain.brightRects)
        let litImage = try XCTUnwrap(LensPageRenderer.draw(page, plan: lit))
        let plainImage = try XCTUnwrap(LensPageRenderer.draw(page, plan: plain))
        // The black block is ink (white on the lens) inside the highlight; the red block is outside.
        let inside = plain.toOutput(LensPageFixtures.inkBlock)
        let outside = plain.toOutput(LensPageFixtures.redBlock)
        let inPlain = try XCTUnwrap(LensPageFixtures.pixel(plainImage, x: Int(inside.midX), y: Int(inside.midY)))
        let inLit = try XCTUnwrap(LensPageFixtures.pixel(litImage, x: Int(inside.midX), y: Int(inside.midY)))
        XCTAssertEqual(inLit.r, inPlain.r, "the highlight at full brightness")
        let outPlain = try XCTUnwrap(LensPageFixtures.pixel(plainImage, x: Int(outside.midX), y: Int(outside.midY)))
        let outLit = try XCTUnwrap(LensPageFixtures.pixel(litImage, x: Int(outside.midX), y: Int(outside.midY)))
        XCTAssertEqual(Int(outLit.r), Int(outPlain.r) / 2, accuracy: 1, "the rest at about half")
        XCTAssertNotEqual(LensPageRenderCache.key(identity: "p", plan: lit), LensPageRenderCache.key(identity: "p", plan: plain))
    }
}
#endif
