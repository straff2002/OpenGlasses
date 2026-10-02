import UIKit
import XCTest
@testable import OpenGlasses

/// Plan HC — the home grid's Model tile draws the active provider's own mark into the same square
/// for every provider (`DockGridMetrics.markGlyphBox`). That only reads at the size of the SF
/// symbols beside it if each mark's artwork **fills its own viewBox** and **parses** on iOS.
///
/// Both failed on main: the OpenAI and ChatGPT artwork carried the brand's clear space inside a
/// 716-unit box (the ink was half the square, so the mark drew at about 14 pt beside a 22 pt
/// camera), and seven of the 24-unit marks wrote their arc flags run together (`a.5.5 0 00-.9 0`),
/// which browsers accept and the system's SVG renderer does not — Gemini drew as a sliver. This
/// renders each bundled mark the way the tile does and measures the ink.
final class ProviderMarkArtworkTests: XCTestCase {

    private let side: CGFloat = 96

    /// The ink's bounding box, in points of a `side`-square render.
    ///
    /// Drawn into a context whose layout is stated (8-bit RGBA, alpha last) rather than one a
    /// renderer chooses — on a wide-colour simulator that is a 16-bit float buffer.
    private func inkBounds(_ image: UIImage) -> CGRect? {
        let width = Int(side), height = Int(side)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.withTintColor(.black, renderingMode: .alwaysOriginal)
            .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        UIGraphicsPopContext()
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 32 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private var bundledMarks: [(LLMProvider, UIImage)] {
        LLMProvider.allCases.compactMap { provider in
            UIImage(named: DockLayout.providerMarkAsset(for: provider)).map { (provider, $0) }
        }
    }

    func testTheMajorProvidersShipAMark() {
        let names = Set(bundledMarks.map(\.0))
        for provider in [LLMProvider.anthropic, .openai, .chatgpt, .gemini] {
            XCTAssertTrue(names.contains(provider), "\(provider.rawValue) has no bundled mark")
        }
    }

    /// Every mark draws, and its longer side fills most of the square — so no provider's mark is
    /// a sliver or a postage stamp beside the tile's symbols.
    /// Groq's tall mark is the least, at 83%; the old OpenAI artwork was 50%.
    func testEveryBundledMarkFillsItsSquare() {
        XCTAssertFalse(bundledMarks.isEmpty)
        for (provider, image) in bundledMarks {
            guard let ink = inkBounds(image) else {
                XCTFail("\(provider.rawValue)'s mark draws nothing — does its path parse on iOS?")
                continue
            }
            let fill = max(ink.width, ink.height) / side
            XCTAssertGreaterThanOrEqual(fill, 0.8,
                                        "\(provider.rawValue)'s mark fills \(Int(fill * 100))% of its square")
        }
    }

    /// …and sits in the middle of it, so the tile's badge corner and the caption clear it alike.
    func testEveryBundledMarkIsCentred() {
        for (provider, image) in bundledMarks {
            guard let ink = inkBounds(image) else { continue }
            XCTAssertEqual(ink.midX, side / 2, accuracy: side * 0.08, "\(provider.rawValue) off-centre across")
            XCTAssertEqual(ink.midY, side / 2, accuracy: side * 0.08, "\(provider.rawValue) off-centre down")
        }
    }
}
