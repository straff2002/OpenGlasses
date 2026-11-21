#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan MU P0 — one picture a row, the picture factor and the fit check. Headless: the factor table
/// and its per-model storage (a private defaults suite), the shrinking step, the Meta backend's
/// one chokepoint (factor 1 sends every picture exactly as drawn), the fit-check screen and its
/// spoken answer, and the guard that nothing sent to the Meta Display puts two pictures side by side.
@MainActor
final class LensPictureScaleTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "mu-picture-scale-tests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func image(_ size: CGSize, colour: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - The factor table

    func testTheReadingToFactorTable() {
        XCTAssertEqual(LensPictureScale.factor(reading: 12), 1)
        XCTAssertEqual(LensPictureScale.factor(reading: 9), 12.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(LensPictureScale.factor(reading: 8), 1.5)
        XCTAssertEqual(LensPictureScale.factor(reading: 6), 2)
        XCTAssertEqual(LensPictureScale.factor(reading: 2), 3, "under the lowest reading counts as it")
        XCTAssertEqual(LensPictureScale.factor(reading: 20), 1, "never enlarged")
        XCTAssertEqual(LensPictureScale.factor(reading: nil), 1, "decision 10: 1 until a fit check")
        XCTAssertEqual(LensPictureScale.factorText(12.0 / 9), "1.33")
        XCTAssertEqual(LensPictureScale.factorText(1), "1")
    }

    func testReadingsAreKeptPerGlassesModelAndTheSimulatorIsAlwaysOne() {
        XCTAssertNil(LensPictureScale.reading(for: "rayBanMeta", in: defaults))
        XCTAssertEqual(LensPictureScale.factor(for: "rayBanMeta", isSimulator: false, in: defaults), 1)
        LensPictureScale.store(.init(highestNumber: 9, tilesSeen: 2), for: "rayBanMeta", in: defaults)
        LensPictureScale.store(.init(highestNumber: 12, tilesSeen: 3), for: "oakleyMetaVanguard", in: defaults)
        XCTAssertEqual(LensPictureScale.reading(for: "rayBanMeta", in: defaults),
                       .init(highestNumber: 9, tilesSeen: 2))
        XCTAssertEqual(LensPictureScale.factor(for: "rayBanMeta", isSimulator: false, in: defaults), 12.0 / 9,
                       accuracy: 0.0001)
        XCTAssertEqual(LensPictureScale.factor(for: "oakleyMetaVanguard", isSimulator: false, in: defaults), 1)
        XCTAssertTrue(LensPictureScale.reading(for: "oakleyMetaVanguard", in: defaults)?.matchesSimulator ?? false)
        XCTAssertEqual(LensPictureScale.factor(for: "rayBanMeta", isSimulator: true, in: defaults), 1,
                       "the simulated Display is what every size was measured on")
        XCTAssertNil(LensPictureScale.reading(for: nil, in: defaults), "an unknown model has its own reading")
        LensPictureScale.store(.init(highestNumber: 8, tilesSeen: 1), for: nil, in: defaults)
        XCTAssertEqual(LensPictureScale.factor(for: "", isSimulator: false, in: defaults), 1.5)
        LensPictureScale.forgetAll(in: defaults)
        XCTAssertNil(LensPictureScale.reading(for: "rayBanMeta", in: defaults))
    }

    // MARK: - Shrinking

    func testAtFactorOneThePictureIsTheSameImage() {
        let drawn = image(CGSize(width: 576, height: 382))
        XCTAssertTrue(LensPictureScale.scaled(drawn, by: 1) === drawn, "not redrawn: the same bytes go")
        XCTAssertTrue(LensPictureScale.scaled(drawn, by: 0.5) === drawn, "never enlarged")
        XCTAssertEqual(LensPictureScale.sentSize(CGSize(width: 576, height: 382), factor: 1), CGSize(width: 576, height: 382))
    }

    func testAFactorShrinksEveryPictureByIt() throws {
        let drawn = image(CGSize(width: 576, height: 382))
        let shrunk = LensPictureScale.scaled(drawn, by: 1.5)
        let cg = try XCTUnwrap(shrunk.cgImage)
        XCTAssertEqual(cg.width, 384)
        XCTAssertEqual(cg.height, 254)
        XCTAssertEqual(LensPictureScale.sentSize(CGSize(width: 576, height: 382), factor: 1.5), CGSize(width: 384, height: 254))
    }

    // MARK: - The Meta backend's one chokepoint

    private func pageScreen(_ picture: HUDPicture) -> HUDScreen {
        var screen = HUDScreen(title: nil, lines: [HUDLine("p. 3", emphasis: .meta)],
                               items: [HUDItem(id: "kv.page.close", label: "Close", style: .outline) {}])
        screen.flow = [.blocks([HUDBlock(id: "mu.page.whole", picture: picture, style: .card)])]
        screen.picture = HUDPicture(image: image(CGSize(width: 120, height: 60)), pixelSize: CGSize(width: 120, height: 60),
                                    contentKey: "thumb")
        return screen
    }

    private func images(in tree: FlexBox) -> [MWDATDisplay.Image] {
        tree.children.flatMap { child -> [MWDATDisplay.Image] in
            if let image = child as? MWDATDisplay.Image { return [image] }
            if let box = child as? FlexBox { return images(in: box) }
            return []
        }
    }

    /// The images `makeScreenView` hands the SDK for `screen`, in the order it builds the tree.
    private func sentPictures(_ backend: MetaDisplayBackend, _ screen: HUDScreen) -> (tree: FlexBox, sent: [UIImage]) {
        var sent: [UIImage] = []
        MetaDisplayBackend.testSentPictureSink = { sent.append($0) }
        defer { MetaDisplayBackend.testSentPictureSink = nil }
        let tree = backend.makeScreenView(screen)
        return (tree, sent)
    }

    private func pixelSize(_ image: UIImage) -> CGSize? {
        image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
    }

    func testAtFactorOneEveryPictureIsSentExactlyAsDrawn() {
        let drawn = image(CGSize(width: 576, height: 382))
        let picture = HUDPicture(image: drawn, pixelSize: CGSize(width: 576, height: 382), contentKey: "page")
        let screen = pageScreen(picture)
        let backend = MetaDisplayBackend()
        backend.pictureFactor = { 1 }
        let (tree, sent) = sentPictures(backend, screen)
        XCTAssertEqual(images(in: tree).count, 2)
        XCTAssertEqual(sent.count, 2)
        let asDrawn = [screen.picture!.image, drawn]
        XCTAssertTrue(sent.allSatisfy { image in asDrawn.contains { $0 === image } }, "the very same images: byte for byte")
        XCTAssertTrue(asDrawn.allSatisfy { image in sent.contains { $0 === image } })
    }

    func testAFactorShrinksThePageTheThumbnailAndTheSlicesButNotTheFitCheck() throws {
        let drawn = image(CGSize(width: 576, height: 382))
        let picture = HUDPicture(image: drawn, pixelSize: CGSize(width: 576, height: 382), contentKey: "page")
        let backend = MetaDisplayBackend()
        backend.pictureFactor = { 1.5 }
        let (tree, sent) = sentPictures(backend, pageScreen(picture))
        XCTAssertEqual(images(in: tree).count, 2)
        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(sent.contains { $0 === drawn }, "the page went shrunk")
        let sizes = sent.compactMap(pixelSize)
        XCTAssertEqual(sizes.count, 2)
        XCTAssertTrue(sizes.contains(CGSize(width: 384, height: 254)), "\(sizes)")
        XCTAssertTrue(sizes.contains(CGSize(width: 80, height: 40)), "\(sizes)")

        // The fit check measures the glasses, so its pictures go as drawn whatever the factor.
        let check = LensFitCheck.screen {}
        let checkSent = sentPictures(backend, check).sent
        let checkDrawn = check.allBlocks.compactMap(\.picture).map(\.image)
        XCTAssertEqual(checkSent.count, checkDrawn.count)
        XCTAssertTrue(zip(checkSent, checkDrawn).allSatisfy { $0 === $1 }, "the fit check's own images")
    }

    /// Every picture reaches the SDK through `lensImage`, the one place the factor is applied.
    func testTheBackendBuildsEveryImageAtTheOneChokepoint() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Display/MetaDisplayBackend.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "Image(image:").count - 1, 2,
                       "one in lensImage, one in the drawsPictures doc comment")
        XCTAssertFalse(source.contains("Image(image: $0.image"), "a picture sent around the factor")
    }

    // MARK: - One picture a row

    func testARowOfPicturesIsSplitOneARow() {
        let picture = HUDPicture(image: image(CGSize(width: 186, height: 120)), pixelSize: CGSize(width: 186, height: 120),
                                 contentKey: "t")
        var screen = HUDScreen(title: nil, lines: [], items: [])
        screen.flow = [.blocks((0..<3).map { HUDBlock(id: "t\($0)", picture: picture) }),
                       .blocks([HUDBlock(id: "a", lines: [HUDLine("one")]), HUDBlock(id: "b", lines: [HUDLine("two")])])]
        XCTAssertTrue(screen.hasPicturesSideBySide)
        let split = screen.onePictureARow()
        XCTAssertFalse(split.hasPicturesSideBySide)
        XCTAssertEqual(split.flow.count, 4, "three pictures one a row; the text row is left as it is")
        XCTAssertEqual(split.allBlocks.map(\.id), ["t0", "t1", "t2", "a", "b"], "nothing lost, the order kept")

        // The backend never builds a row box with two images in it.
        func holdsImage(_ component: any ViewComponent) -> Bool {
            if component is MWDATDisplay.Image { return true }
            return (component as? FlexBox)?.children.contains(where: holdsImage) ?? false
        }
        func rowsWithTwoImages(_ box: FlexBox) -> Int {
            let here = box.direction == .row && box.children.filter(holdsImage).count > 1 ? 1 : 0
            return here + box.children.compactMap { $0 as? FlexBox }.map(rowsWithTwoImages).reduce(0, +)
        }
        let backend = MetaDisplayBackend()
        backend.pictureFactor = { 1 }
        XCTAssertEqual(rowsWithTwoImages(backend.makeScreenView(screen)), 0)
    }

    // MARK: - The fit check

    func testTheFitCheckScreen() throws {
        let screen = LensFitCheck.screen {}
        XCTAssertEqual(LensFitCheck.rulerWidth, 576, "exactly the lens column")
        XCTAssertEqual(LensFitCheck.numberSpacing, 48)
        XCTAssertEqual(LensFitCheck.numberCentre(1), 24)
        XCTAssertEqual(LensFitCheck.numberCentre(12), 552)
        let pictures = screen.allBlocks.compactMap(\.picture)
        XCTAssertEqual(pictures.count, 2, "the ruler, and the three tiles as one picture")
        XCTAssertEqual(pictures[0].pixelSize.width, 576)
        XCTAssertEqual(try XCTUnwrap(pictures[0].image.cgImage).width, 576, "drawn one pixel a lens pixel")
        XCTAssertEqual(try XCTUnwrap(pictures[1].image.cgImage).width, 576)
        XCTAssertTrue(pictures.allSatisfy { !$0.scalesForLens })
        XCTAssertFalse(screen.hasPicturesSideBySide, "one a row: the tiles are under the ruler")
        XCTAssertEqual(screen.flow.count, 2)
        XCTAssertEqual(LensFitCheck.tileOrigins.count, 3)
        XCTAssertEqual(LensFitCheck.tileOrigins.last.map { $0 + LensFitCheck.tileWidth } ?? 0, 576, accuracy: 0.001)
        XCTAssertEqual(LensFitCheck.tileWidth, 186)
        XCTAssertEqual(screen.items.map(\.id), [LensFitCheck.ItemID.close])
        XCTAssertTrue(HUDExit.hasExit(screen))
        XCTAssertLessThanOrEqual(LensPageFrame.fixedHeight(.init(metaLines: 1, bodyLines: 2, hasPicture: false))
                                 + LensFitCheck.rulerHeight + LensFitCheck.tilesHeight + 2 * LensPageFrame.gapPixels,
                                 CGFloat(HUDCanvas.metaDisplay.heightPixels), "the whole check on the lens at once")
    }

    func testTheSpokenAnswer() {
        XCTAssertEqual(LensFitCheckAnswer.parse("twelve and three")?.highest, 12)
        XCTAssertEqual(LensFitCheckAnswer.parse("twelve and three")?.tiles, 3)
        XCTAssertEqual(LensFitCheckAnswer.parse("I can read 9, and two boxes")?.highest, 9)
        XCTAssertEqual(LensFitCheckAnswer.parse("I can read 9, and two boxes")?.tiles, 2)
        XCTAssertEqual(LensFitCheckAnswer.parse("eight and a box")?.tiles, 1)
        XCTAssertEqual(LensFitCheckAnswer.parse("eleven")?.highest, 11)
        XCTAssertNil(LensFitCheckAnswer.parse("eleven")?.tiles)
        XCTAssertNil(LensFitCheckAnswer.parse("what is the factory charge"))
        XCTAssertNil(LensFitCheckAnswer.parse("40 and 3"), "not a ruler number")
        XCTAssertNil(LensFitCheckAnswer.parse("what is on page four"), "a question with a number in it is not an answer")
    }

    func testTheFitCheckKeepsTheReadingAndReportsIt() async {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }
        let session = LensFitCheckSession(display: display, defaults: defaults)
        session.model = { "rayBanMeta" }
        XCTAssertEqual(session.reportLines, ["Lens fit check (rayBanMeta): not run; pictures sent at factor 1"])
        XCTAssertNil(session.start())
        XCTAssertTrue(session.isRunning)
        for _ in 0..<6 { await Task.yield() }
        XCTAssertTrue(session.ownsLens)
        XCTAssertFalse(session.handleVoice("what is on page four"))
        XCTAssertTrue(session.handleVoice("nine and two"))
        XCTAssertFalse(session.isRunning, "the answer ends the check")
        XCTAssertEqual(session.lastReading, .init(highestNumber: 9, tilesSeen: 2))
        XCTAssertEqual(LensPictureScale.factor(for: "rayBanMeta", isSimulator: false, in: defaults), 12.0 / 9,
                       accuracy: 0.0001)
        XCTAssertEqual(session.reportLines,
                       ["Lens fit check (rayBanMeta): read 9 of 12, tiles seen 2 of 3; pictures sent at factor 1.33"])
    }
}
#endif
