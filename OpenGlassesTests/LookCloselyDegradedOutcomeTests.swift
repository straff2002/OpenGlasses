import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR4 — what happens when the requested photo is not good enough to read.
///
/// The rule under test is the one a blind wearer cannot check for themselves: an unreadable picture
/// produces a move to make or the part that was legible, and never the digits, names, dates or
/// instructions that were not. Every assertion about copy here is really an assertion about that.
@MainActor
final class LookCloselyDegradedOutcomeTests: XCTestCase {

    private final class FakeInjector: LiveSessionInjecting {
        var canInject = true
        var isBusyForInjection = false
        var liveSessionIdentity = 1
        private(set) var injected: [Data] = []
        func injectSharpImage(jpegData: Data) { injected.append(jpegData) }
        func injectText(_ text: String, completeTurn: Bool) {}
    }

    /// Hand-built reports, because these cases are about the decision rather than about pixels.
    private func report(sharpness: Double?, luma: Double?) -> CaptureQualityReport {
        CaptureQualityReport(sourcePixelSize: CGSize(width: 800, height: 600),
                             deliveredPixelSize: CGSize(width: 800, height: 600),
                             jpegByteCount: 30_000,
                             sharpness: sharpness,
                             meanLuma: luma,
                             scope: .liveSession,
                             cameraSession: 0,
                             liveSessionIdentity: 1,
                             capturedAt: .distantFuture)
    }

    private func makeTool(injector: FakeInjector,
                          captures: [CaptureQualityReport],
                          recognized: OCRService.Result = OCRService.Result(text: "", blocks: []),
                          posture: @escaping () -> PowerPosture = { .normal },
                          attempts: Attempts = Attempts()) -> LookCloselyTool {
        LookCloselyTool(
            captureSharpStill: { _ in
                let index = min(attempts.count, captures.count - 1)
                attempts.count += 1
                return .captured(jpeg: Data(count: 2048), report: captures[index])
            },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: posture,
            recognizeText: { _ in recognized },
            now: { .distantPast })
    }

    /// Mutable capture counter shared with the closure.
    final class Attempts { var count = 0 }

    // MARK: - Bounded retry

    func testABlurredCaptureIsRetriedExactlyOnceAndThenExplained() async throws {
        let injector = FakeInjector()
        let attempts = Attempts()
        let blurry = report(sharpness: 8, luma: 0.6)
        let tool = makeTool(injector: injector, captures: [blurry, blurry], attempts: attempts)

        let result = try await tool.execute(args: ["reason": "read this label"])

        XCTAssertEqual(attempts.count, 2, "one automatic re-capture, and only one")
        XCTAssertTrue(injector.injected.isEmpty, "an unreadable picture must not reach the model")
        XCTAssertTrue(result.contains("Hold still and move a little closer to the text."), result)
    }

    /// The retry is worth having: a hand that moved during the first shutter is the case that
    /// reliably fixes itself.
    func testASecondCaptureThatCameOutSharpIsInjected() async throws {
        let injector = FakeInjector()
        let attempts = Attempts()
        let tool = makeTool(injector: injector,
                            captures: [report(sharpness: 8, luma: 0.6),
                                       report(sharpness: 700, luma: 0.55)],
                            attempts: attempts)

        let result = try await tool.execute(args: ["reason": "read this"])

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(injector.injected.count, 1, "injected once, and only once, per request")
        XCTAssertEqual(result, LookCloselyPolicy.sharpFrameInstruction)
    }

    /// The retry is a request to capture, not a bypass: power posture still decides.
    func testPowerReserveStopsTheRetry() async throws {
        let injector = FakeInjector()
        let attempts = Attempts()
        var posture = PowerPosture.normal
        let blurry = report(sharpness: 8, luma: 0.6)
        let tool = LookCloselyTool(
            captureSharpStill: { _ in
                attempts.count += 1
                posture = .reserve
                return .captured(jpeg: Data(count: 2048), report: blurry)
            },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { posture },
            recognizeText: { _ in OCRService.Result(text: "", blocks: []) },
            now: { .distantPast })

        let result = try await tool.execute(args: ["reason": "read this"])

        XCTAssertEqual(attempts.count, 1, "reserve must not spend a second full-res capture")
        XCTAssertTrue(injector.injected.isEmpty)
        XCTAssertTrue(result.contains("Hold still"), result)
    }

    // MARK: - Which instruction

    func testDarknessAsksForLightNotForSteadiness() async throws {
        let injector = FakeInjector()
        let dark = report(sharpness: 4, luma: 0.03)
        let tool = makeTool(injector: injector, captures: [dark, dark])

        let result = try await tool.execute(args: ["reason": "what's the expiry date"])

        XCTAssertTrue(result.contains("It's too dark to read; find more light."), result)
        XCTAssertFalse(result.contains("Hold still"),
                       "telling someone to hold still in a dark room is the wrong move")
    }

    /// A non-reading question gets the general line: "closer to the text" is wrong advice when
    /// there is no text, and a wearer who cannot check it pays for the wrong advice.
    func testANonReadingRequestGetsTheGeneralSteadinessLine() async throws {
        let injector = FakeInjector()
        let blurry = report(sharpness: 8, luma: 0.6)
        let tool = makeTool(injector: injector, captures: [blurry, blurry])

        let result = try await tool.execute(args: ["reason": "how far away is the door"])

        XCTAssertTrue(result.contains("Hold still for a moment so I can get a sharper picture."),
                      result)
        XCTAssertFalse(result.contains("closer to the text"))
    }

    // MARK: - Never invent

    func testTheDegradedCopyForbidsInventingDetail() async throws {
        let injector = FakeInjector()
        let blurry = report(sharpness: 8, luma: 0.6)
        let tool = makeTool(injector: injector, captures: [blurry, blurry])

        let result = try await tool.execute(args: ["reason": "read this label"])

        XCTAssertTrue(result.contains("do NOT answer it from the streamed view"))
        XCTAssertTrue(result.contains("Never guess characters, digits, names, dates or instructions"))
        XCTAssertTrue(result.contains("what you expect this kind of item to say"),
                      "the packaging-context guess is the specific failure the plan names")
        XCTAssertTrue(ReadingCorpusFixtures.digits(result).isEmpty,
                      "a guidance line must not carry digits at all — there is nothing it could "
                      + "honestly have read")
    }

    // MARK: - Partial transcription

    func testConfidentOnDeviceTextIsOfferedAsAClearlyLabelledPartial() async throws {
        let injector = FakeInjector()
        let blurry = report(sharpness: 8, luma: 0.6)
        let recognized = OCRService.Result(
            text: "Zorbatol 25 mg\nEXP 03/2027",
            blocks: [
                .init(text: "Zorbatol 25 mg", confidence: 0.91, boundingBox: .zero),
                .init(text: "EXP 03/2027", confidence: 0.62, boundingBox: .zero),
                // Below the partial floor: legible enough to feed a model, not legible enough to
                // read aloud verbatim to someone who cannot check it.
                .init(text: "Lot 4471B", confidence: 0.34, boundingBox: .zero),
            ])
        let tool = makeTool(injector: injector, captures: [blurry, blurry], recognized: recognized)

        let result = try await tool.execute(args: ["reason": "read this label"])

        XCTAssertTrue(result.contains("PARTIAL TEXT"), result)
        XCTAssertTrue(result.contains("Zorbatol 25 mg"))
        XCTAssertTrue(result.contains("EXP 03/2027"))
        XCTAssertFalse(result.contains("4471B"),
                       "a block below the partial-confidence floor must not be read aloud")
        XCTAssertTrue(result.contains("PARTIAL reading"))
        XCTAssertTrue(result.contains("Do NOT complete, correct or extend them"))
        XCTAssertTrue(injector.injected.isEmpty,
                      "the picture was unreadable; the transcription is the whole answer")
    }

    func testNoConfidentTextFallsBackToTheInstruction() async throws {
        let injector = FakeInjector()
        let blurry = report(sharpness: 8, luma: 0.6)
        let recognized = OCRService.Result(
            text: "rn 0 5",
            blocks: [.init(text: "rn 0 5", confidence: 0.31, boundingBox: .zero)])
        let tool = makeTool(injector: injector, captures: [blurry, blurry], recognized: recognized)

        let result = try await tool.execute(args: ["reason": "read this label"])

        XCTAssertFalse(result.contains("PARTIAL TEXT"))
        XCTAssertTrue(result.contains("Hold still and move a little closer to the text."))
    }

    func testThePartialFloorIsStricterThanTheOCRServiceFloor() {
        XCTAssertGreaterThan(ReadingCaptureOutcome.partialConfidenceFloor,
                             OCRService().minimumConfidence)
    }

    // MARK: - No false success cue

    /// Plan FF P0/PR2's cue means "the photo you asked for exists and is in front of the model".
    /// An unreadable picture is not that.
    func testAnUnreadableCaptureNeverPlaysTheSuccessCue() async throws {
        let injector = FakeInjector()
        let blurry = report(sharpness: 8, luma: 0.6)
        var cues = 0
        let tool = LookCloselyTool(
            captureSharpStill: { _ in .captured(jpeg: Data(count: 2048), report: blurry) },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal },
            recognizeText: { _ in OCRService.Result(text: "", blocks: []) },
            now: { .distantPast },
            onCaptureSucceeded: { cues += 1 })

        _ = try await tool.execute(args: ["reason": "read this"])

        XCTAssertEqual(cues, 0)
    }

    // MARK: - The decision table, directly

    func testTheDecisionTable() {
        XCTAssertEqual(ReadingCaptureOutcome.decide(quality: .usable, attemptsSoFar: 1,
                                                    isReadingRequest: true), .inject)
        XCTAssertEqual(ReadingCaptureOutcome.decide(quality: .tooBlurry, attemptsSoFar: 1,
                                                    isReadingRequest: true), .retry(.tooBlurry))
        XCTAssertEqual(ReadingCaptureOutcome.decide(quality: .tooDark, attemptsSoFar: 1,
                                                    isReadingRequest: true), .retry(.tooDark))
        guard case .explain = ReadingCaptureOutcome.decide(quality: .tooBlurry, attemptsSoFar: 2,
                                                           isReadingRequest: true) else {
            return XCTFail("the second unusable capture ends the retries")
        }
        XCTAssertEqual(ReadingCaptureOutcome.maximumAutomaticRetries, 1)
    }

    /// Each unavailable reason tells the wearer its own true thing rather than a single generic
    /// failure — "no picture", "the picture is out of date", "I couldn't prepare it".
    func testEachUnavailableReasonHasItsOwnHonestLine() {
        let lines = [FilteredStillResult.Reason.noStill,
                     .noFreshView,
                     .filterUnavailable].map(ReadingCaptureOutcome.unavailable)
        XCTAssertEqual(Set(lines).count, 3)
        for line in lines {
            XCTAssertTrue(line.contains("Never guess characters, digits, names, dates or instructions"))
            XCTAssertTrue(line.contains("do NOT answer"))
        }
    }
}
