import CoreGraphics
import JavaScriptCore
import PDFKit
import XCTest
@testable import OpenGlasses

/// Display & HUD › Highlight colour: the palette's rules, the stored choice, and each surface the
/// app draws itself (manual-page marks, the turn arrow, the Web App) taking it, with Standard
/// leaving every one as it was.
final class LensHighlightColourTests: XCTestCase {

    // MARK: - The palette

    func testStandardKeepsWhatEachSurfaceDrewBefore() {
        let standard = LensHighlightColour.standard
        XCTAssertNil(standard.hex)
        XCTAssertEqual(standard.markHex, AccentColors.aiAccentDarkHex, "coral marks")
        XCTAssertEqual(standard.arrowHex, 0xFFFFFF, "a white arrow")
        XCTAssertEqual(standard.webTextHex, 0xFFFFFF, "white Web App text")
        XCTAssertEqual(standard.webFocusHex, 0xFFB000, "an amber focus ring")
        XCTAssertEqual(standard.keySuffix, "", "every existing picture key is unchanged")
    }

    func testAChosenColourDrawsEverySurfaceInIt() {
        for colour in LensHighlightColour.allCases where colour != .standard {
            XCTAssertNotNil(colour.hex)
            XCTAssertEqual(colour.markHex, colour.hex, "\(colour)")
            XCTAssertEqual(colour.arrowHex, colour.hex, "\(colour)")
            XCTAssertEqual(colour.webTextHex, colour.hex, "\(colour)")
            XCTAssertEqual(colour.keySuffix, ":hl-\(colour.rawValue)")
        }
    }

    func testTheFocusRingStaysApartFromTheText() {
        for colour in LensHighlightColour.allCases {
            XCTAssertNotEqual(colour.webFocusHex, colour.webTextHex,
                              "\(colour): the focused button must not look like the rest")
        }
    }

    func testEveryChoiceIsBrightAndNoneIsCyanOrBlue() {
        for colour in LensHighlightColour.allCases {
            for hex in [colour.markHex, colour.arrowHex, colour.webTextHex, colour.webFocusHex] {
                let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                XCTAssertGreaterThan(luma, 120, "\(colour): black is clear on the lens, so a dark colour fades")
                XCTAssertFalse(b > r && b > 0x80, "\(colour): no blue")
                XCTAssertFalse(g > 0xC0 && b > 0xC0 && r < 0x80, "\(colour): no cyan (house rule)")
            }
        }
    }

    func testCSSIsSixHexDigits() {
        XCTAssertEqual(LensHighlightColour.css(0x5BE37D), "#5BE37D")
        XCTAssertEqual(LensHighlightColour.css(0x00000A), "#00000A")
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

    // MARK: - The Web App

    @MainActor
    func testStandardLeavesTheWebAppPayloadAsItWas() {
        let screen = sampleScreen()
        let payload = WebHUDPayload.from(screen: screen, highlight: .standard)
        XCTAssertNil(payload.textColour)
        XCTAssertNil(payload.focusColour)
        XCTAssertEqual(payload.renderKey, screen.renderKey)
    }

    @MainActor
    func testAChosenColourRidesOnTheWebAppPayloadAndItsKey() throws {
        let screen = sampleScreen()
        let payload = WebHUDPayload.from(screen: screen, highlight: .amber)
        XCTAssertEqual(payload.textColour, "#FFB000")
        XCTAssertEqual(payload.focusColour, "#FFFFFF", "amber text keeps a white ring")
        XCTAssertEqual(payload.renderKey, screen.renderKey + ":hl-amber", "the page redraws on the next poll")
        XCTAssertEqual(payload.title, "Pump check")
        XCTAssertEqual(payload.items.map(\.id), ["done", "skip"])

        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(payload), encoding: .utf8))
        XCTAssertTrue(json.contains("\"textColour\":\"#FFB000\""))
    }

    @MainActor
    func testTheWebAppPageDrawsFromItsColourVariables() {
        let html = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: sampleScreen(), highlight: .green)))
        XCTAssertTrue(html.contains(WebHUDRenderer.colourScript))
        XCTAssertTrue(html.contains("color: var(--text)"))
        XCTAssertTrue(html.contains("border-color: var(--focus)"))
        XCTAssertTrue(html.contains("#ffb000"), "Standard's amber stays the fallback")
        XCTAssertTrue(html.contains("\"textColour\":\"#5BE37D\""))
    }

    func testTheWebAppTakesOnlyAColourIntoItsCSS() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(WebHUDRenderer.colourScript)
        func colour(_ value: Any?) -> String? {
            context.objectForKeyedSubscript("colour")?
                .call(withArguments: [value ?? NSNull(), "#fff"])?.toString()
        }
        XCTAssertEqual(colour("#5BE37D"), "#5BE37D")
        XCTAssertEqual(colour(nil), "#fff", "Standard sends none")
        XCTAssertEqual(colour("red"), "#fff")
        XCTAssertEqual(colour("#5BE37D; background: url(x)"), "#fff")
        XCTAssertEqual(colour("#FFF"), "#fff", "six digits only")
        XCTAssertEqual(colour(42), "#fff")
    }

    // MARK: - Helpers

    private func sampleScreen() -> HUDScreen {
        HUDScreen(title: "Pump check", lines: [
            HUDLine("Close the valve", icon: .hazard),
            HUDLine("Step 2 of 5", emphasis: .meta),
        ], items: [
            HUDItem(id: "done", label: "Done", style: .primary) {},
            HUDItem(id: "skip", label: "Skip") {},
        ])
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        LensPageFixtures.pixel(image, x: x, y: y)
    }
}
