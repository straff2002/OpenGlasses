import XCTest
import UIKit
@testable import OpenGlasses

/// Verifies the outgoing-image guard that keeps cloud vision requests under Anthropic's
/// 5 MB inline-image cap (and the high-res 2576 px long-edge ceiling). This matters specifically on
/// the iPhone-camera fallback / photo-tool paths, which capture at full sensor resolution
/// — the one place a 12 MP JPEG can blow past 5 MB and 400 the request.
final class LLMImagePreparerTests: XCTestCase {

    /// Solid-colour JPEG at a given pixel size (small byte footprint — exercises the
    /// dimension guard rather than the byte guard).
    private func jpeg(width: Int, height: Int, quality: CGFloat = 0.9) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality)!
    }

    private func longEdge(of data: Data) -> Int {
        guard let cg = UIImage(data: data)?.cgImage else { return 0 }
        return max(cg.width, cg.height)
    }

    func testOversizedImageIsDownscaledToLongEdgeCeiling() {
        let input = jpeg(width: 3024, height: 2016)   // ~12 MP, like a full iPhone capture
        XCTAssertGreaterThan(longEdge(of: input), Int(LLMImagePreparer.maxLongEdge))

        let out = LLMImagePreparer.prepared(input)
        XCTAssertLessThanOrEqual(longEdge(of: out), Int(LLMImagePreparer.maxLongEdge))
        XCTAssertLessThanOrEqual(out.count, LLMImagePreparer.maxBytes)
        // Aspect ratio preserved (3:2 → long edge 2576, short edge ~1717).
        if let cg = UIImage(data: out)?.cgImage {
            XCTAssertEqual(Double(cg.width) / Double(cg.height), 3.0 / 2.0, accuracy: 0.02)
        }
    }

    func testInBoundsImageIsReturnedUntouched() {
        let input = jpeg(width: 1280, height: 720)    // already under both ceilings
        let out = LLMImagePreparer.prepared(input)
        // Fast path returns the exact same bytes — no wasteful re-encode.
        XCTAssertEqual(out, input)
        XCTAssertLessThanOrEqual(longEdge(of: out), Int(LLMImagePreparer.maxLongEdge))
    }

    func testSquareOversizedImageIsBounded() {
        let input = jpeg(width: 4000, height: 4000)
        let out = LLMImagePreparer.prepared(input)
        XCTAssertLessThanOrEqual(longEdge(of: out), Int(LLMImagePreparer.maxLongEdge))
        XCTAssertLessThanOrEqual(out.count, LLMImagePreparer.maxBytes)
    }

    func testUndecodableDataIsReturnedUnchanged() {
        // Fail open — dropping the image would be worse than passing it through.
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(LLMImagePreparer.prepared(garbage), garbage)
    }

    // MARK: - Degenerate-frame guard (Plan BH hardening)

    func testTinyPlaceholderFramesAreDegenerate() {
        // The 1×1 placeholder failure mode, and anything under the minimum edge.
        XCTAssertTrue(LLMImagePreparer.isDegenerate(jpeg(width: 1, height: 1)))
        XCTAssertTrue(LLMImagePreparer.isDegenerate(jpeg(width: 16, height: 16)))
        XCTAssertTrue(LLMImagePreparer.isDegenerate(jpeg(width: 31, height: 8)))
    }

    func testUndecodableDataIsDegenerate() {
        XCTAssertTrue(LLMImagePreparer.isDegenerate(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertTrue(LLMImagePreparer.isDegenerate(Data()))
    }

    func testTightTPMCapsBytesAndLongEdge() {
        let size = CGSize(width: 1280, height: 720)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let noisy = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for y in stride(from: 0, to: 720, by: 2) {
                for x in stride(from: 0, to: 1280, by: 2) {
                    UIColor(
                        hue: CGFloat((x + y) % 360) / 360,
                        saturation: 1,
                        brightness: 1,
                        alpha: 1
                    ).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }.jpegData(compressionQuality: 0.95)!
        XCTAssertGreaterThan(noisy.count, LLMImagePreparer.Limits.tightTPM.maxBytes)

        let out = LLMImagePreparer.prepared(noisy, tightTPM: true)
        XCTAssertLessThanOrEqual(longEdge(of: out), Int(LLMImagePreparer.Limits.tightTPM.maxLongEdge))
        XCTAssertLessThanOrEqual(out.count, LLMImagePreparer.Limits.tightTPM.maxBytes)
    }

    func testRealFramesAreNotDegenerate() {
        XCTAssertFalse(LLMImagePreparer.isDegenerate(jpeg(width: 32, height: 32)),
                       "the minimum edge itself passes")
        XCTAssertFalse(LLMImagePreparer.isDegenerate(jpeg(width: 1280, height: 720)))
    }
}
