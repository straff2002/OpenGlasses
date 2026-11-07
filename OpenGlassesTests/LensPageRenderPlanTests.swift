import CoreGraphics
import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan KV P1 — the lens picture: the plan's pixel decisions (inversion, the photographed stretch,
/// the crop's mapping, where the marks and the position frame go), the drawing over an invented
/// PDF page, and the cache the pictures are kept in.
final class LensPageRenderPlanTests: XCTestCase {

    private let page = LensPageFixtures.letter

    // MARK: - Tones

    func testInversionTurnsPaperClearAndInkBright() {
        XCTAssertTrue(LensPageRenderPlan.invertLightness(255, 255, 255) == (0, 0, 0), "white paper → black (clear)")
        XCTAssertTrue(LensPageRenderPlan.invertLightness(0, 0, 0) == (255, 255, 255), "black ink → white")
        let grey = LensPageRenderPlan.invertLightness(64, 64, 64)
        XCTAssertTrue(grey == (191, 191, 191))
    }

    func testInversionKeepsTheHue() {
        // A red wire stays red; a dark blue goes light blue, not orange.
        XCTAssertTrue(LensPageRenderPlan.invertLightness(255, 0, 0) == (255, 0, 0))
        let blue = LensPageRenderPlan.invertLightness(0, 0, 128)
        XCTAssertGreaterThan(blue.2, blue.0)
        XCTAssertGreaterThan(blue.2, 200)
    }

    func testTheStretchTakesGreyPaperToWhite() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[180] = 900     // the grey paper of a photographed page
        histogram[40] = 100      // its ink
        let levels = LensPageRenderPlan.stretchLevels(histogram: histogram)
        XCTAssertEqual(levels.black, 40)
        XCTAssertEqual(levels.white, 180)
        XCTAssertEqual(LensPageRenderPlan.stretch(180, black: levels.black, white: levels.white), 255)
        XCTAssertEqual(LensPageRenderPlan.stretch(40, black: levels.black, white: levels.white), 0)
        XCTAssertEqual(LensPageRenderPlan.stretch(10, black: levels.black, white: levels.white), 0, "clamped")
    }

    func testAFlatPageIsNotStretched() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[200] = 1_000
        let levels = LensPageRenderPlan.stretchLevels(histogram: histogram)
        XCTAssertEqual(levels.black, 0)
        XCTAssertEqual(levels.white, 255)
        XCTAssertTrue(LensPageRenderPlan.stretchLevels(histogram: []) == (0, 255))
    }

    // MARK: - Crop and marks

    func testTheCropIsDrawnAtTheContentWidth() {
        let crop = CGRect(x: 100, y: 200, width: 192, height: 96)
        let plan = LensPageRenderPlan(pageSize: page, crop: crop, tone: .lineArt, showsPosition: false)
        XCTAssertEqual(plan.outputSize, CGSize(width: 576, height: 288), "the column's width, the crop's shape")
        XCTAssertEqual(plan.scale, 3, accuracy: 0.0001, "a 192 pt crop draws 3 px per point")
        XCTAssertEqual(plan.toOutput(CGRect(x: 150, y: 250, width: 10, height: 10)),
                       CGRect(x: 150, y: 150, width: 30, height: 30))
    }

    /// A viewport's plan is drawn at its picture box, one lens pixel per image pixel.
    func testAViewportsPlanIsDrawnAtItsPictureBox() {
        let layout = LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt)
        for box in [LensPageFrame.pictureBox(citation: true, hint: true), LensPageFrame.pictureBox(citation: false, hint: false)] {
            let plan = LensPageRenderPlan(layout: layout, viewport: LensPageViewport(wholePage: page, box: box))
            XCTAssertEqual(plan.outputSize, box)
        }
    }

    func testTheWholePageLeavesBlackMarginsOnTheShortSide() {
        let viewport = LensPageViewport(wholePage: page)
        let plan = LensPageRenderPlan(layout: LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt),
                                      viewport: viewport)
        let inOutput = plan.pageInOutput
        XCTAssertEqual(inOutput.height, plan.outputSize.height, accuracy: 0.01)
        XCTAssertEqual(inOutput.minX, (plan.outputSize.width - inOutput.width) / 2, accuracy: 0.01,
                       "centred, margins either side")
        XCTAssertGreaterThan(inOutput.minX, 0)
    }

    func testMarksInTheCropArePlacedAndNumberedOnlyWhenSeveral() {
        let first = CGRect(x: 120, y: 220, width: 100, height: 12)
        let second = CGRect(x: 120, y: 260, width: 80, height: 12)
        let offCrop = CGRect(x: 500, y: 700, width: 50, height: 12)
        let marks = LensPageMarks(marks: [
            .init(number: 1, lineRects: [first], bounds: first),
            .init(number: 2, lineRects: [second], bounds: second),
            .init(number: 3, lineRects: [offCrop], bounds: offCrop),
        ], showsNumbers: true)
        let crop = CGRect(x: 100, y: 200, width: 200, height: 160)
        let plan = LensPageRenderPlan(pageSize: page, crop: crop, tone: .lineArt, passageMarks: marks,
                                      showsPosition: false)
        XCTAssertEqual(plan.marks.map(\.number), [1, 2], "the mark outside the crop is not drawn")
        let pad = LensPageRenderPlan.markPaddingPoints
        XCTAssertEqual(plan.marks[0].rect, plan.toOutput(first.insetBy(dx: -pad, dy: -pad)))

        let single = LensPageMarks(marks: [.init(number: 1, lineRects: [first], bounds: first)], showsNumbers: false)
        let unnumbered = LensPageRenderPlan(pageSize: page, crop: crop, tone: .lineArt, passageMarks: single,
                                            showsPosition: false)
        XCTAssertEqual(unnumbered.marks.map(\.number), [nil])
    }

    func testPictureAreasAreOutlinedWithoutANumber() {
        let area = CGRect(x: 50, y: 400, width: 300, height: 120)
        let plan = LensPageRenderPlan(pageSize: page, crop: LensPageViewport(wholePage: page).cropRect,
                                      tone: .lineArt, pictureAreas: [area], showsPosition: false)
        XCTAssertEqual(plan.marks.count, 1)
        XCTAssertNil(plan.marks[0].number)
    }

    func testThePositionFrameShowsOnlyWhenZoomedAndSaysWhereTheCropIs() {
        let whole = LensPageViewport(wholePage: page)
        let layout = LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt)
        XCTAssertNil(LensPageRenderPlan(layout: layout, viewport: whole).positionFrame)

        var zoomed = whole
        zoomed.zoomIn()
        zoomed.jump(to: .topLeft)
        let frame = try? XCTUnwrap(LensPageRenderPlan(layout: layout, viewport: zoomed).positionFrame)
        XCTAssertNotNil(frame)
        guard let frame else { return }
        let output = LensPageRenderPlan(layout: layout, viewport: zoomed).outputSize
        XCTAssertLessThanOrEqual(frame.page.maxX, output.width)
        XCTAssertLessThanOrEqual(frame.page.maxY, output.height)
        XCTAssertEqual(max(frame.page.width, frame.page.height),
                       min(output.width, output.height) * LensPageRenderPlan.positionFrameShare, accuracy: 0.01)
        XCTAssertEqual(frame.crop.minX, frame.page.minX, accuracy: 0.01, "top left of the page")
        XCTAssertEqual(frame.crop.minY, frame.page.minY, accuracy: 0.01)
        XCTAssertTrue(frame.page.insetBy(dx: -0.01, dy: -0.01).contains(frame.crop))
    }

    // MARK: - Drawing an invented page

    private func draw(_ url: URL, crop: CGRect, tone: LensPageRenderPlan.Tone = .lineArt,
                      marks: LensPageMarks? = nil, showsPosition: Bool = false) throws -> UIImage {
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        let plan = LensPageRenderPlan(pageSize: page, crop: crop, tone: tone, passageMarks: marks,
                                      showsPosition: showsPosition)
        return try XCTUnwrap(LensPageRenderer.draw(pdfPage, plan: plan))
    }

    func testTheWholePageDrawsInvertedAtThePictureBox() throws {
        let url = try LensPageFixtures.pdf()
        let crop = LensPageViewport(wholePage: page).cropRect
        let image = try draw(url, crop: crop)
        XCTAssertEqual(image.cgImage?.width, 576)
        XCTAssertEqual(image.cgImage?.height, 462)
        let scale = 576 / crop.width
        func pixel(_ point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
            LensPageFixtures.pixel(image, x: Int((point.x - crop.minX) * scale), y: Int((point.y - crop.minY) * scale))
        }
        let ink = try XCTUnwrap(pixel(CGPoint(x: LensPageFixtures.inkBlock.midX, y: LensPageFixtures.inkBlock.midY)))
        XCTAssertGreaterThan(ink.r, 240, "black ink glows")
        let paper = try XCTUnwrap(pixel(CGPoint(x: 450, y: 300)))
        XCTAssertLessThan(Int(paper.r) + Int(paper.g) + Int(paper.b), 15, "paper is clear")
        let margin = try XCTUnwrap(LensPageFixtures.pixel(image, x: 5, y: 300))
        XCTAssertLessThan(Int(margin.r) + Int(margin.g) + Int(margin.b), 15, "past the page is clear too")
        let red = try XCTUnwrap(pixel(CGPoint(x: LensPageFixtures.redBlock.midX, y: LensPageFixtures.redBlock.midY)))
        XCTAssertGreaterThan(red.r, 200)
        XCTAssertLessThan(red.g, 60, "a red wire stays red")
    }

    func testAZoomedCropIsRenderedAtTheLensResolution() throws {
        let url = try LensPageFixtures.pdf()
        // A crop across the ink block's right edge, at 6 px per point.
        let crop = CGRect(x: 252, y: 150, width: 96, height: 96)
        let image = try draw(url, crop: crop)
        XCTAssertEqual(image.cgImage?.width, 576)
        let inside = try XCTUnwrap(LensPageFixtures.pixel(image, x: 258, y: 300))   // page x = 295
        let outside = try XCTUnwrap(LensPageFixtures.pixel(image, x: 318, y: 300))  // page x = 305
        XCTAssertGreaterThan(inside.r, 240)
        XCTAssertLessThan(outside.r, 15, "the edge is crisp within a few pixels, not a blur")
    }

    func testAPhotographedPageIsStretchedBeforeItIsInverted() throws {
        let grey = UIColor(white: 0.7, alpha: 1)
        let ink = UIColor(white: 0.2, alpha: 1)
        let url = try LensPageFixtures.pdf(paper: grey, ink: ink)
        let crop = LensPageViewport(wholePage: page).cropRect
        let scale = 576 / crop.width
        let paperX = Int((450 - crop.minX) * scale), paperY = Int(300 * scale)
        let line = try XCTUnwrap(LensPageFixtures.pixel(try draw(url, crop: crop, tone: .lineArt), x: paperX, y: paperY))
        let photo = try XCTUnwrap(LensPageFixtures.pixel(try draw(url, crop: crop, tone: .photographed),
                                                         x: paperX, y: paperY))
        XCTAssertGreaterThan(line.r, 50, "grey paper inverted is a haze")
        XCTAssertLessThan(photo.r, 20, "stretched first, the paper goes clear")
    }

    func testMarksAndThePositionFrameAreDrawnInTheAccent() throws {
        let url = try LensPageFixtures.pdf()
        let markRect = CGRect(x: 400, y: 300, width: 100, height: 20)
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [markRect], bounds: markRect)], showsNumbers: false)
        var viewport = LensPageViewport(wholePage: page)
        viewport.zoomIn()
        let crop = viewport.cropRect
        let plan = LensPageRenderPlan(pageSize: page, crop: crop, tone: .lineArt, passageMarks: marks, showsPosition: true)
        let image = try draw(url, crop: crop, marks: marks, showsPosition: true)

        let outline = try XCTUnwrap(plan.marks.first?.rect)
        let edge = try XCTUnwrap(LensPageFixtures.pixel(image, x: Int(outline.minX), y: Int(outline.midY)))
        let hex = AccentColors.aiAccentDarkHex
        XCTAssertEqual(Int(edge.r), Int((hex >> 16) & 0xFF), accuracy: 6)
        XCTAssertEqual(Int(edge.g), Int((hex >> 8) & 0xFF), accuracy: 6)
        XCTAssertEqual(Int(edge.b), Int(hex & 0xFF), accuracy: 6)

        let frame = try XCTUnwrap(plan.positionFrame)
        let cropEdge = try XCTUnwrap(LensPageFixtures.pixel(image, x: Int(frame.crop.midX), y: Int(frame.crop.minY)))
        XCTAssertGreaterThan(cropEdge.r, 180, "the crop's place on the page is outlined in the accent")
    }

    // MARK: - Laying out an invented page

    func testLayoutOpensOnAPicturedTableAtAReadableStep() async throws {
        let url = try LensPageFixtures.pdf()
        let area = ManualTable.PictureArea(physical: 1, rect: CGRect(x: 80, y: 500, width: 160, height: 90))
        let elsewhere = ManualTable.PictureArea(physical: 2, rect: CGRect(x: 0, y: 0, width: 600, height: 700))
        let request = LensPageRequest(source: url, page: 1, pictureAreas: [area, elsewhere])
        let layout = try await XCTUnwrapAsync(await LensPageRenderer.layout(request))
        XCTAssertEqual(layout.pageSize, page)
        XCTAssertEqual(layout.pictureAreas, [area.rect], "only this page's areas")
        XCTAssertEqual(layout.focus.source, .pictureArea)
        XCTAssertFalse(layout.openingViewport.isWholePage)
        XCTAssertTrue(layout.openingViewport.cropRect.contains(area.rect))
        XCTAssertNil(layout.reading, "a pictured table keeps the picture")
    }

    func testAPageThatIsNotThereLaysOutNothing() async throws {
        let url = try LensPageFixtures.pdf()
        let missing = await LensPageRenderer.layout(LensPageRequest(source: url, page: 4))
        XCTAssertNil(missing)
    }

    // MARK: - The cache

    @MainActor
    func testTheCacheKeysByPageAndCropAndForgetsTheOldest() {
        let cache = LensPageRenderCache(capacity: 2)
        let layout = LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt)
        var viewport = LensPageViewport(wholePage: page)
        let whole = LensPageRenderPlan(layout: layout, viewport: viewport)
        viewport.zoomIn()
        let zoomed = LensPageRenderPlan(layout: layout, viewport: viewport)

        let a = LensPageRenderCache.key(identity: "page-a", plan: whole)
        let b = LensPageRenderCache.key(identity: "page-a", plan: zoomed)
        let c = LensPageRenderCache.key(identity: "page-b", plan: whole)
        XCTAssertNotEqual(a, b, "the crop is part of the key")
        XCTAssertNotEqual(a, c, "so is the page")
        XCTAssertEqual(a, LensPageRenderCache.key(identity: "page-a", plan: whole))

        func picture(_ key: String) -> HUDPicture {
            HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 576, height: 462), contentKey: key)
        }
        cache.store(picture(a), for: a)
        cache.store(picture(b), for: b)
        _ = cache.picture(for: a)                 // a is used again, so b is the oldest
        cache.store(picture(c), for: c)
        XCTAssertTrue(cache.contains(a))
        XCTAssertFalse(cache.contains(b))
        XCTAssertTrue(cache.contains(c))
        XCTAssertEqual(cache.count, 2)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }
}

/// `XCTUnwrap` for an async expression's result.
private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
