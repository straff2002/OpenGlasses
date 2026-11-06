#if !AVENKIN_PHONE_ONLY
import XCTest
import SwiftUI
@testable import OpenGlasses

/// Snapshot smoke test for the on-phone HUD renderer (`HUDPreviewView`): render a task
/// card to an image and assert it actually drew bright content (text + coral buttons)
/// over the dark "glass" panel — i.e. the FlexBox tree-walker produces visible output.
/// (Reference-image comparison would need a snapshot library; this is the dependency-free
/// equivalent and the device-less validation the HUD relies on.)
@MainActor
final class HUDPreviewSnapshotTests: XCTestCase {

    func testTaskCardRendersVisibleContent() async throws {
        let screen = HUDScreen(
            title: "Torque bolts",
            lines: [HUDLine("45 Nm, 2 passes", emphasis: .secondary),
                    HUDLine("De-energize first", icon: .hazard, emphasis: .secondary)],
            items: [HUDItem(id: "done", label: "Done", icon: .success, style: .primary) {},
                    HUDItem(id: "back", label: "Back", style: .outline) {}]
        )

        // On a cold GPU (e.g. a freshly-erased simulator) the first ImageRenderer pass can time out
        // building the Metal pipeline and return a blank image, failing the brightness check
        // spuriously. Render until visible content appears, letting the pipeline warm up between
        // attempts. On a warm renderer this passes on the first attempt with no delay.
        var image: UIImage?
        var fraction = 0.0
        for attempt in 0..<12 {
            let renderer = ImageRenderer(content: HUDPreviewView(screen: screen).frame(width: 320, height: 240))
            renderer.scale = 2
            if let rendered = renderer.uiImage {
                image = rendered
                fraction = Self.brightFraction(rendered)
                if fraction > 0.002 { break }
            }
            if attempt < 11 { try await Task.sleep(nanoseconds: 400_000_000) }
        }

        let finalImage = try XCTUnwrap(image, "ImageRenderer produced no image")
        XCTAssertGreaterThan(finalImage.size.width, 0)
        XCTAssertGreaterThan(finalImage.size.height, 0)
        XCTAssertTrue(fraction > 0.002,
                      "the preview should render visible text/buttons over the dark panel (after warm-up)")
    }

    /// Plan KP P1: a paged answer card, cut for each backend's page shape, draws visible text and
    /// buttons (its page, its footer, Next and Actions).
    func testAPagedAnswerCardRendersForEachBackend() async throws {
        let answer = """
        Turn the isolator off before you open the panel. Check the capacitor with a meter, \
        because it can hold a charge for minutes after the power is cut. If the reading is above \
        five volts, discharge it with an insulated resistor. Then swap the contactor.
        """
        for geometry in [TeleprompterPaginator.Geometry.raybanDisplay, .evenG2] {
            let pages = HUDAnswerPager.pages(for: answer, geometry: geometry)
            XCTAssertGreaterThan(pages.count, 1, "paged for \(geometry.maxLines)×\(geometry.maxChars)")
            let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: []) { _ in })
            XCTAssertEqual(screen.lines.last?.text, "1/\(pages.count)")
            let fraction = try await renderedBrightFraction(screen)
            XCTAssertTrue(fraction > 0.002, "the card should render visibly (\(geometry.maxChars) chars)")
        }
    }

    private func renderedBrightFraction(_ screen: HUDScreen) async throws -> Double {
        var fraction = 0.0
        for attempt in 0..<12 {
            let renderer = ImageRenderer(content: HUDPreviewView(screen: screen).frame(width: 320, height: 320))
            renderer.scale = 2
            if let rendered = renderer.uiImage {
                fraction = Self.brightFraction(rendered)
                if fraction > 0.002 { break }
            }
            if attempt < 11 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
        return fraction
    }

    /// Fraction of pixels noticeably brighter than the near-black panel.
    private static func brightFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bright = 0, i = 0
        while i < pixels.count {
            if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 240 { bright += 1 }
            i += 4
        }
        return Double(bright) / Double(w * h)
    }
}

#endif
