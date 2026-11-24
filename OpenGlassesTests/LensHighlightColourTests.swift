import CoreGraphics
import PDFKit
import XCTest
@testable import OpenGlasses

/// Display & HUD › Highlight colour: the palette's rules, the stored choice, and each surface the
/// app draws itself (manual-page marks, the turn arrow) taking it, with Standard leaving each one
/// as it was.
final class LensHighlightColourTests: XCTestCase {

    // MARK: - The palette

    func testStandardKeepsWhatEachSurfaceDrewBefore() {
        let standard = LensHighlightColour.standard
        XCTAssertNil(standard.hex)
        XCTAssertEqual(standard.markHex, AccentColors.aiAccentDarkHex, "coral marks")
        XCTAssertEqual(standard.arrowHex, 0xFFFFFF, "a white arrow")
        XCTAssertEqual(standard.keySuffix, "", "every existing picture key is unchanged")
    }

    func testAChosenColourDrawsEverySurfaceInIt() {
        for colour in LensHighlightColour.allCases where colour != .standard {
            XCTAssertNotNil(colour.hex)
            XCTAssertEqual(colour.markHex, colour.hex, "\(colour)")
            XCTAssertEqual(colour.arrowHex, colour.hex, "\(colour)")
            XCTAssertEqual(colour.keySuffix, ":hl-\(colour.rawValue)")
        }
    }

    func testEveryChoiceIsBrightAndNoneIsCyanOrBlue() {
        for colour in LensHighlightColour.allCases {
            for hex in [colour.markHex, colour.arrowHex] {
                let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                XCTAssertGreaterThan(luma, 120, "\(colour): black is clear on the lens, so a dark colour fades")
                XCTAssertFalse(b > r && b > 0x80, "\(colour): no blue")
                XCTAssertFalse(g > 0xC0 && b > 0xC0 && r < 0x80, "\(colour): no cyan (house rule)")
            }
        }
    }

    // MARK: - The stored choice

    func testTheStoredChoiceIsStandardUntilOneIsMade() throws {
        let suite = "LensHighlightColourTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LensHighlightColour.stored(in: defaults), .standard)
        defaults.set("magenta", forKey: LensHighlightColour.storageKey)
        XCTAssertEqual(LensHighlightColour.stored(in: defaults), .standard, "an unknown value reads as Standard")
        defaults.set(LensHighlightColour.green.rawValue, forKey: LensHighlightColour.storageKey)
        XCTAssertEqual(LensHighlightColour.stored(in: defaults), .green)
    }

    // MARK: - The turn arrow

    @MainActor
    func testTheArrowIsDrawnInTheChosenColour() throws {
        let standard = try XCTUnwrap(HUDTurnArrow.picture(for: .continueStraight, highlight: .standard))
        XCTAssertEqual(standard.contentKey, "lc.nav.arrow:0")
        XCTAssertEqual(Int(pixel(standard.image, x: 60, y: 80)?.g ?? 0), 255, accuracy: 4, "Standard stays white")

        let green = try XCTUnwrap(HUDTurnArrow.picture(for: .continueStraight, highlight: .green))
        XCTAssertEqual(green.contentKey, "lc.nav.arrow:0:hl-green", "a new colour is a new frame")
        let shaft = try XCTUnwrap(pixel(green.image, x: 60, y: 80))
        XCTAssertEqual(Int(shaft.r), 0x5B, accuracy: 6)
        XCTAssertEqual(Int(shaft.g), 0xE3, accuracy: 6)
        XCTAssertEqual(Int(shaft.b), 0x7D, accuracy: 6)
        let ground = try XCTUnwrap(pixel(green.image, x: 400, y: 60))
        XCTAssertLessThan(Int(ground.r) + Int(ground.g) + Int(ground.b), 15, "the rest stays black, clear on the lens")
    }

    // MARK: - Manual-page marks

    func testMarksAreDrawnInTheChosenColour() throws {
        let page = LensPageFixtures.letter
        let url = try LensPageFixtures.pdf()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        let markRect = CGRect(x: 400, y: 300, width: 100, height: 20)
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [markRect], bounds: markRect)], showsNumbers: false)
        var viewport = LensPageViewport(wholePage: page)
        viewport.zoomIn()
        let plan = LensPageRenderPlan(pageSize: page, crop: viewport.cropRect, tone: .lineArt,
                                      passageMarks: marks, showsPosition: true)
        let image = try XCTUnwrap(LensPageRenderer.draw(pdfPage, plan: plan, highlight: .yellow))

        let outline = try XCTUnwrap(plan.marks.first?.rect)
        let edge = try XCTUnwrap(LensPageFixtures.pixel(image, x: Int(outline.minX), y: Int(outline.midY)))
        XCTAssertEqual(Int(edge.r), 0xFF, accuracy: 6)
        XCTAssertEqual(Int(edge.g), 0xE1, accuracy: 6)
        XCTAssertEqual(Int(edge.b), 0x4D, accuracy: 6)

        let frame = try XCTUnwrap(plan.positionFrame)
        let cropEdge = try XCTUnwrap(LensPageFixtures.pixel(image, x: Int(frame.crop.midX), y: Int(frame.crop.minY)))
        XCTAssertGreaterThan(cropEdge.g, 180, "the position frame's crop takes it too")
    }

    func testARequestDrawsStandardUntilTheSessionSetsAColour() throws {
        let request = LensPageRequest(source: try LensPageFixtures.pdf(), page: 1)
        XCTAssertEqual(request.highlight, .standard)
    }

    // MARK: - Helpers

    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        LensPageFixtures.pixel(image, x: x, y: y)
    }
}
