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

    func testTaskCardRendersVisibleContent() throws {
        let screen = HUDScreen(
            title: "Torque bolts",
            lines: [HUDLine("45 Nm, 2 passes", emphasis: .secondary),
                    HUDLine("De-energize first", icon: .hazard, emphasis: .secondary)],
            items: [HUDItem(id: "done", label: "Done", icon: .success, style: .primary) {},
                    HUDItem(id: "back", label: "Back", style: .outline) {}]
        )
        let renderer = ImageRenderer(content: HUDPreviewView(screen: screen).frame(width: 320, height: 240))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer produced no image")

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertTrue(Self.brightFraction(image) > 0.002,
                      "the preview should render visible text/buttons over the dark panel")
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
