import XCTest
import UIKit
@testable import OpenGlasses

/// Tests for Plan J pure logic: frame-quality pre-check, dedup, and the hazard prompt contract.
/// The ambient camera+LLM loop is not unit-tested.
@MainActor
final class NavigationAssistTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: Int = 64) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.cgImage!
    }

    private func variedImage(size: Int = 64) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            UIColor.gray.setFill(); ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size / 2))
        }.cgImage!
    }

    func testDarkFrameIsUnusable() {
        XCTAssertFalse(NavigationAssistService.isFrameUsable(solidImage(.black)))
    }

    func testUniformFrameIsUnusable() {
        // A flat mid-gray frame: bright enough but no variance (blurred/featureless).
        XCTAssertFalse(NavigationAssistService.isFrameUsable(solidImage(.gray)))
    }

    func testVariedFrameIsUsable() {
        XCTAssertTrue(NavigationAssistService.isFrameUsable(variedImage()))
    }

    func testDedupSuppressesRepeatCallout() {
        XCTAssertTrue(NavigationAssistService.isSimilar("Step down, two o'clock, one meter",
                                                        "Step down at two o'clock about one meter"))
        XCTAssertFalse(NavigationAssistService.isSimilar("Step down, two o'clock",
                                                         "Open doorway ahead, twelve o'clock"))
    }

    func testPromptDemandsJSONAndClockPositions() {
        let p = NavigationAssistService.systemPrompt
        XCTAssertTrue(p.contains("valid JSON"))
        XCTAssertTrue(p.lowercased().contains("clock position"))
        XCTAssertTrue(p.lowercased().contains("hazard"))
    }

    func testNavAdviceHighUrgencyMapsToHighSpeech() {
        let advice = AssistiveAdvice.parse(#"{"advice":"Vehicle approaching, ten o'clock","urgency":"high"}"#)
        XCTAssertEqual(advice?.urgency.speechUrgency, .high)
    }
}
