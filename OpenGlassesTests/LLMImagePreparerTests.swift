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

    // MARK: - Presets (the shrink-further half)

    /// A preset may shrink an image harder than the API requires — that is the whole feature, and
    /// it is what makes a tight-token provider usable.
    func testACompactPresetCapsBothBytesAndLongEdge() {
        let limits = LLMImagePreparer.limits(for: .compact)
        let big = noisyJPEG(width: 2000, height: 1200)
        XCTAssertGreaterThan(big.count, limits.maxBytes, "fixture must actually exceed the cap it is testing")

        let out = LLMImagePreparer.prepared(big, limits: limits)
        XCTAssertLessThanOrEqual(longEdge(of: out), Int(limits.maxLongEdge))
        XCTAssertLessThanOrEqual(out.count, limits.maxBytes)
    }

    /// The one a preset may **not** do. "Original" means "do not optimise", not "ignore the
    /// endpoint" — Anthropic 400s an inline image over 5 MB, and that is a property of the API
    /// rather than a user preference, so an oversized capture is still brought under the ceiling.
    func testOriginalIsStillHeldToTheProviderCeiling() {
        XCTAssertEqual(LLMImagePreparer.limits(for: .original), .apiCeiling)

        let huge = noisyJPEG(width: 4032, height: 3024)
        let out = LLMImagePreparer.prepared(huge, limits: LLMImagePreparer.limits(for: .original))
        XCTAssertLessThanOrEqual(out.count, LLMImagePreparer.maxBytes,
                                 "an image over the hard limit is a guaranteed 400, whatever the user picked")
    }

    /// A custom preset's sliders are clamped against the same ceiling, so no combination of
    /// settings can produce a request the endpoint will refuse.
    func testCustomLimitsCannotExceedTheProviderCeiling() {
        let limits = LLMImagePreparer.limits(for: .custom)
        XCTAssertLessThanOrEqual(limits.maxBytes, LLMImagePreparer.maxBytes)
        XCTAssertLessThanOrEqual(limits.maxLongEdge, LLMImagePreparer.maxLongEdge)
    }

    /// An image already inside a preset's limits is returned byte-identical — no re-encode, so
    /// the common glasses path (already-small frames) pays nothing for the feature existing.
    func testAnImageInsideTheLimitsIsNotReEncoded() {
        let small = jpeg(width: 640, height: 480)
        XCTAssertEqual(LLMImagePreparer.prepared(small, limits: LLMImagePreparer.limits(for: .compact)), small)
    }

    /// The ladder always reaches the shared floor, whatever the slider says — otherwise a high
    /// custom quality could run out of steps while still over the byte cap.
    func testQualityLadderDescendsToTheFloor() {
        for start in [CGFloat(0.95), 0.75, 0.4, 0.2] {
            let ladder = LLMImagePreparer.qualityLadder(from: start)
            XCTAssertEqual(ladder.first ?? -1, start, accuracy: 0.001)
            XCTAssertEqual(ladder.last ?? -1, 0.2, accuracy: 0.001)
            XCTAssertEqual(ladder, ladder.sorted(by: >), "a ladder that rises would re-inflate the payload")
        }
    }

    /// Stored raw values are a migration surface: they are what is already in UserDefaults on
    /// devices running the build that shipped them.
    func testPresetRawValuesAreStable() {
        XCTAssertEqual(LLMImagePreset.original.rawValue, "off")
        XCTAssertEqual(LLMImagePreset.full.rawValue, "full")
        XCTAssertNil(LLMImagePreset(rawValue: "nonsense"))
    }

    /// Noise defeats JPEG's entropy coding, so this actually lands over the byte caps a flat
    /// colour would sail under. Filled as a raw pixel buffer (deterministic xorshift) rather
    /// than per-pixel CoreGraphics fills, which took minutes at 12 MP.
    private func noisyJPEG(width: Int, height: Int) -> Data {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            let words = buffer.bindMemory(to: UInt64.self)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for i in words.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[i] = state
            }
        }
        let cg = CGImage(width: width, height: height,
                         bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: pixels as CFData)!,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cg).jpegData(compressionQuality: 1.0)!
    }

    func testRealFramesAreNotDegenerate() {
        XCTAssertFalse(LLMImagePreparer.isDegenerate(jpeg(width: 32, height: 32)),
                       "the minimum edge itself passes")
        XCTAssertFalse(LLMImagePreparer.isDegenerate(jpeg(width: 1280, height: 720)))
    }
}
