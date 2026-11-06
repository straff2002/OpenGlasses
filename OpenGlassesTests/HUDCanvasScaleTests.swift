import XCTest
@testable import OpenGlasses

/// Plan KP P4: the lens canvases, their fit into the phone's space, and the estimated text sizes.
/// Pure and SDK-free, so this runs in the phone-only build too.
final class HUDCanvasScaleTests: XCTestCase {

    // MARK: Canvases

    func testTheTwoLensCanvases() {
        XCTAssertEqual(HUDCanvas.metaDisplay.widthPixels, 600)
        XCTAssertEqual(HUDCanvas.metaDisplay.heightPixels, 600)
        XCTAssertEqual(HUDCanvas.metaDisplay.density, 160)
        XCTAssertEqual(HUDCanvas.metaDisplay.aspectRatio, 1)
        XCTAssertEqual(HUDCanvas.evenG2.widthPixels, 576)
        XCTAssertEqual(HUDCanvas.evenG2.heightPixels, 288)
        XCTAssertEqual(HUDCanvas.evenG2.aspectRatio, 2)
        for backend in HUDCanvasBackend.allCases {
            XCTAssertEqual(HUDCanvas.canvas(for: backend).backend, backend)
        }
    }

    #if !AVENKIN_PHONE_ONLY
    func testTheChosenBackendPicksItsCanvas() {
        XCTAssertEqual(HUDCanvas.canvas(for: DisplayBackendChoice.metaRayBan), .metaDisplay)
        XCTAssertEqual(HUDCanvas.canvas(for: DisplayBackendChoice.evenG2), .evenG2)
    }
    #endif

    // MARK: Meta Display, 600 × 600

    func testTheDisplayFitsANarrowPhoneWidthAndLetterboxesDown() {
        let fit = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 320, height: 800), displayScale: 3)
        XCTAssertEqual(fit.size, CGSize(width: 320, height: 320))
        XCTAssertEqual(fit.origin, CGPoint(x: 0, y: 240))
        XCTAssertEqual(fit.pointsPerPixel, 320.0 / 600.0, accuracy: 1e-9)
        XCTAssertTrue(fit.isLetterboxed)
    }

    func testTheDisplayIsNeverDrawnPastOnePointPerPixelInAWideSpace() {
        let fit = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 1024, height: 700), displayScale: 2)
        XCTAssertEqual(fit.pointsPerPixel, HUDCanvasScale.maxPointsPerPixel)
        XCTAssertEqual(fit.size, CGSize(width: 600, height: 600))
        XCTAssertEqual(fit.origin, CGPoint(x: 212, y: 50), "centred in the space it has")
        XCTAssertTrue(fit.isLetterboxed)
    }

    func testTheDisplayInAnExactSquareIsNotLetterboxed() {
        let fit = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 360, height: 360), displayScale: 3)
        XCTAssertEqual(fit.size, CGSize(width: 360, height: 360))
        XCTAssertEqual(fit.origin, CGPoint.zero)
        XCTAssertFalse(fit.isLetterboxed)
    }

    func testAnUnboundedHeightDoesNotConstrainTheFit() {
        let fit = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 300, height: CGFloat.infinity), displayScale: 2)
        XCTAssertEqual(fit.size, CGSize(width: 300, height: 300))
        XCTAssertEqual(fit.origin, CGPoint.zero)
        let open = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity), displayScale: 2)
        XCTAssertEqual(open.size, CGSize(width: 600, height: 600), "no finite side fits at the cap")
    }

    func testAnEmptySpaceGivesAnEmptyCanvas() {
        let fit = HUDCanvasScale.fit(.metaDisplay, in: CGSize.zero, displayScale: 3)
        XCTAssertEqual(fit.size, CGSize.zero)
        XCTAssertEqual(fit.pointsPerPixel, 0)
    }

    // MARK: Even G2, 576 × 288

    func testTheEvenPanelFitsANarrowWidthAtItsTwoToOneShape() {
        let fit = HUDCanvasScale.fit(.evenG2, in: CGSize(width: 320, height: 800), displayScale: 3)
        XCTAssertEqual(fit.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(fit.origin, CGPoint(x: 0, y: 320))
        XCTAssertEqual(fit.pointsPerPixel, 320.0 / 576.0, accuracy: 1e-9)
    }

    func testTheEvenPanelDropsAnOddDevicePixelRatherThanBlurAnEdge() {
        // 321 device pixels can't hold a 2:1 rectangle on whole pixels; 320 × 160 can.
        let fit = HUDCanvasScale.fit(.evenG2, in: CGSize(width: 321, height: 400), displayScale: 1)
        XCTAssertEqual(fit.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(fit.origin.x, 0, "half a pixel of letterbox rounds down onto the grid")
    }

    func testTheEvenPanelIsCappedInAWideSpace() {
        let fit = HUDCanvasScale.fit(.evenG2, in: CGSize(width: 1366, height: 1024), displayScale: 2)
        XCTAssertEqual(fit.size, CGSize(width: 576, height: 288))
        XCTAssertEqual(fit.pointsPerPixel, 1)
        XCTAssertEqual(fit.origin, CGPoint(x: 395, y: 368))
    }

    func testTheEvenPanelInAShortWideSpaceIsLimitedByHeightAndCentredAcross() {
        let fit = HUDCanvasScale.fit(.evenG2, in: CGSize(width: 1000, height: 100), displayScale: 2)
        XCTAssertEqual(fit.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(fit.origin, CGPoint(x: 400, y: 0))
        XCTAssertTrue(fit.isLetterboxed)
    }

    // MARK: Whole-pixel mapping, every space

    func testEveryFitLandsOnWholeDevicePixelsKeepsTheAspectAndFits() {
        for canvas in [HUDCanvas.metaDisplay, .evenG2] {
            for displayScale in [1.0, 2.0, 3.0] as [CGFloat] {
                for width in stride(from: CGFloat(40), through: 900, by: 13) {
                    for height in [90.0, 211.0, 333.5, 640.0, .infinity] as [CGFloat] {
                        let space = CGSize(width: width, height: height)
                        let fit = HUDCanvasScale.fit(canvas, in: space, displayScale: displayScale)
                        let label = "\(canvas.backend) in \(width)×\(height) @\(displayScale)x"
                        for value in [fit.size.width, fit.size.height, fit.origin.x, fit.origin.y] {
                            let pixels = value * displayScale
                            XCTAssertEqual(pixels, pixels.rounded(), accuracy: 1e-6, "off the pixel grid: \(label)")
                        }
                        XCTAssertEqual(fit.size.width * displayScale,
                                       (fit.size.height * displayScale) * canvas.aspectRatio,
                                       accuracy: 1e-6, "aspect: \(label)")
                        XCTAssertLessThanOrEqual(fit.pointsPerPixel, HUDCanvasScale.maxPointsPerPixel, label)
                        XCTAssertLessThanOrEqual(fit.origin.x + fit.size.width, width + 1e-6, label)
                        if height.isFinite {
                            XCTAssertLessThanOrEqual(fit.origin.y + fit.size.height, height + 1e-6, label)
                        }
                        XCTAssertEqual(fit.points(CGFloat(canvas.widthPixels)), fit.size.width, accuracy: 1e-6, label)
                        // Never more than one aspect unit (2 device pixels for Even) short of filling the width.
                        if !height.isFinite, width < CGFloat(canvas.widthPixels) {
                            XCTAssertGreaterThan(fit.size.width * displayScale, width * displayScale - 3, label)
                        }
                    }
                }
            }
        }
    }

    // MARK: Token sizes (estimates)

    func testTheDisplaysTokenSizesAreEstimatesWithBodyInTheExpectedRange() {
        let canvas = HUDCanvas.metaDisplay
        let heading = canvas.textSize(.heading), body = canvas.textSize(.body), meta = canvas.textSize(.meta)
        XCTAssertTrue((24...32).contains(body.pixels), "body text on the Display runs about 24–32 px")
        XCTAssertGreaterThan(heading.pixels, body.pixels)
        XCTAssertGreaterThan(body.pixels, meta.pixels)
        for size in [heading, body, meta] {
            XCTAssertTrue(size.isEstimate, "uncalibrated until a lens is photographed")
            XCTAssertGreaterThan(size.lineHeightPixels, size.pixels)
        }
        XCTAssertTrue(canvas.sizesAreEstimates)
    }

    func testTheEvenPanelHasOneEstimatedSizeThatHoldsTheRenderersBudget() {
        let canvas = HUDCanvas.evenG2
        let sizes = HUDTextToken.allCases.map(canvas.textSize)
        XCTAssertEqual(Set(sizes.map(\.pixels)).count, 1, "the panel draws one size")
        XCTAssertTrue(sizes.allSatisfy(\.isEstimate))
        XCTAssertTrue(canvas.sizesAreEstimates)
        // The renderer's 44 cells and 8 lines fill the panel at the estimated metrics.
        let cells = CGFloat(EvenScreenRenderer.charBudget) * HUDCanvas.evenCharAdvancePixels
        XCTAssertEqual(cells + 2 * canvas.evenLeftMarginPixels, CGFloat(canvas.widthPixels))
        XCTAssertEqual(CGFloat(EvenScreenRenderer.maxLines) * HUDCanvas.evenLinePitchPixels,
                       CGFloat(canvas.heightPixels))
        XCTAssertLessThanOrEqual(CGFloat(TeleprompterPaginator.Geometry.evenG2.maxChars)
                                 * HUDCanvas.evenCharAdvancePixels, CGFloat(canvas.widthPixels),
                                 "a paged answer's line fits across the panel")
    }

    func testFontPointsScaleWithTheCanvas() {
        let half = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 300, height: 300), displayScale: 2)
        XCTAssertEqual(half.fontPoints(.body), HUDCanvas.metaDisplay.textSize(.body).pixels / 2, accuracy: 1e-9)
        let full = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 900, height: 900), displayScale: 2)
        XCTAssertEqual(full.fontPoints(.heading), HUDCanvas.metaDisplay.textSize(.heading).pixels, accuracy: 1e-9)
    }

    func testTheAccessibilitySummarySaysTheSizesAreEstimates() {
        for canvas in [HUDCanvas.metaDisplay, .evenG2] {
            let summary = canvas.accessibilitySummary
            XCTAssertTrue(summary.contains(canvas.displayName), summary)
            XCTAssertTrue(summary.contains("\(canvas.widthPixels)"), summary)
            XCTAssertTrue(summary.contains("\(canvas.heightPixels)"), summary)
            XCTAssertTrue(summary.lowercased().contains("estimate"), summary)
            XCTAssertFalse(summary.contains("KP"), "no plan letters in what the wearer hears")
        }
    }
}
