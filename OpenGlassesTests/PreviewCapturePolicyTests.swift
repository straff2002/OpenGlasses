import XCTest
@testable import OpenGlasses

/// Plan LT §1 — what the camera preview may draw while the screen is recorded, shared or mirrored.
final class PreviewCapturePolicyTests: XCTestCase {

    func testWithTheBlurOffNothingChangesWhileCaptured() {
        XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: false, isCaptured: true,
                                                   scope: .onDevicePreview, hasFilteredSource: true), .raw)
        XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: false, isCaptured: true,
                                                   scope: .onDevicePreview, hasFilteredSource: false), .raw)
    }

    func testAScreenThatIsNotCapturedShowsThePreviewRaw() {
        XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: true, isCaptured: false,
                                                   scope: .onDevicePreview, hasFilteredSource: true), .raw)
    }

    func testCapturedWithTheBlurOnShowsTheRelaysFramesOrNothing() {
        XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: true, isCaptured: true,
                                                   scope: .onDevicePreview, hasFilteredSource: true),
                       .filtered, "the glasses preview switches to the blur relay's frames")
        XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: true, isCaptured: true,
                                                   scope: .onDevicePreview, hasFilteredSource: false),
                       .blank, "the phone viewfinder has no filtered source, so it goes blank")
    }

    /// Only the preview is this policy's to decide; every other scope has its own filter rule.
    func testOtherScopesAreNotThisPolicysBusiness() {
        for scope in PrivacyFilterScope.allCases where scope != .onDevicePreview {
            XCTAssertEqual(PreviewCapturePolicy.decide(blurOn: true, isCaptured: true, scope: scope,
                                                       hasFilteredSource: false), .raw, scope.rawValue)
        }
    }

    /// A filtered decision draws the relay's frame only while it is fresh — never raw pixels in
    /// the gap before the first one, nor after the relay stops producing them.
    func testAFilteredDecisionIsBlankWithoutAFreshFrame() {
        let wait = PreviewCapturePolicy.filteredFrameWait
        XCTAssertEqual(wait, 0.5)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.filtered, filteredFrameAge: nil), .blank)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.filtered, filteredFrameAge: 0.1), .filtered)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.filtered, filteredFrameAge: wait), .filtered)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.filtered, filteredFrameAge: wait + 0.01), .blank)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.filtered, filteredFrameAge: -1), .blank,
                       "a frame from the future is a clock fault, not a fresh frame")
    }

    func testResolveLeavesRawAndBlankAsTheyAre() {
        XCTAssertEqual(PreviewCapturePolicy.resolve(.raw, filteredFrameAge: nil), .raw)
        XCTAssertEqual(PreviewCapturePolicy.resolve(.blank, filteredFrameAge: 0.1), .blank)
    }

    func testTheLinesArePlainAndShort() {
        for line in [PreviewCapturePolicy.hiddenLine, PreviewCapturePolicy.filteredLine] {
            XCTAssertFalse(line.isEmpty)
            XCTAssertLessThan(line.count, 80)
            XCTAssertFalse(line.contains("Plan"), "no plan letters in rendered copy")
        }
    }
}
