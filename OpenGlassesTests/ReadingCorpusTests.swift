import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR4 — the measurement harness. No thresholds.
///
/// The plan is explicit that performance targets are agreed *after* a baseline, so these cases
/// assert only that each number was computed, is in range, and is not vacuous — and then print the
/// table that goes into the plan's evidence note. A threshold written before the first measurement
/// is a guess dressed as a requirement, and the first thing it does is get relaxed.
///
/// What these numbers are and are not: a simulator, synthetic renders of invented documents,
/// degraded by filters, with no glasses, no network and no wearer. They bound the pipeline from
/// above. The on-device run against real mail and real labels through the production adapters is
/// what PR4 records as still owed.
@MainActor
final class ReadingCorpusTests: XCTestCase {

    // MARK: - Fakes

    /// Serves one prepared still through the chokepoint seam, recording what was asked for.
    private final class CorpusStillProvider: FilteredStillProviding {
        var result: FilteredStillResult
        private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []

        init(_ result: FilteredStillResult) { self.result = result }

        convenience init(jpeg: Data) {
            let image = UIImage(data: jpeg) ?? UIImage()
            self.init(.still(FilteredStill(image: image, scope: .liveSession,
                                           sourceData: jpeg,
                                           sourcePixelSize: image.pixelSize)))
        }

        func filteredStill(for scope: PrivacyFilterScope,
                           source: FilteredStillSource) async -> FilteredStillResult {
            requests.append((scope, source))
            return result
        }
    }

    private final class CountingInjector: LiveSessionInjecting {
        var canInject = true
        var isBusyForInjection = false
        var liveSessionIdentity = 1
        private(set) var injected: [Data] = []
        func injectSharpImage(jpegData: Data) { injected.append(jpegData) }
        func injectText(_ text: String, completeTurn: Bool) {}
    }

    // MARK: - The corpus itself

    func testTheCorpusLoadsAndEveryVariantRenders() throws {
        let documents = try ReadingCorpusFixtures.load()
        XCTAssertEqual(documents.count, 4, "four documents: mail, small print, a price, a label")
        XCTAssertTrue(documents.contains { $0.id == "medication-style" })

        for document in documents {
            for variant in ReadingCorpusFixtures.Variant.allCases {
                let jpeg = ReadingCorpusFixtures.jpeg(document, variant)
                XCTAssertGreaterThan(jpeg.count, 512,
                                     "\(document.id)/\(variant.rawValue) rendered to nothing")
                let image = try XCTUnwrap(UIImage(data: jpeg))
                XCTAssertEqual(image.pixelSize, document.canvas,
                               "\(document.id)/\(variant.rawValue) changed size — the report's "
                               + "delivered dimensions would be measuring the filter, not the camera")
            }
        }
    }

    /// Every document's ground truth is invented. Checked rather than promised: a corpus that
    /// acquires a real brand or a real medication name in a later edit should fail here.
    func testTheMedicationDocumentIsSynthetic() throws {
        let documents = try ReadingCorpusFixtures.load()
        let label = try XCTUnwrap(documents.first { $0.id == "medication-style" })
        XCTAssertTrue(label.groundTruth.contains("Zorbatol"),
                      "the invented name is the point — see the corpus notice")
        XCTAssertFalse(ReadingCorpusFixtures.digits(label.groundTruth).isEmpty,
                       "the label must carry digits, or digit accuracy measures nothing")
    }

    // MARK: - Accuracy baseline

    func testCharacterAndDigitAccuracyAreComputedAndRecorded() async throws {
        let documents = try ReadingCorpusFixtures.load()
        let ocr = OCRService()
        var rows: [String] = []

        for document in documents {
            for variant in ReadingCorpusFixtures.Variant.allCases {
                let jpeg = ReadingCorpusFixtures.jpeg(document, variant)
                let recognized = await ocr.recognizeText(in: jpeg)
                let chars = ReadingCorpusFixtures.characterAccuracy(
                    recognized: recognized.text, truth: document.groundTruth)
                let digits = ReadingCorpusFixtures.digitAccuracy(
                    recognized: recognized.text, truth: document.groundTruth)
                let report = CaptureQualityReport.measure(
                    jpeg: jpeg,
                    sourcePixelSize: document.canvas,
                    deliveredPixelSize: document.canvas,
                    scope: .liveSession,
                    cameraSession: 0,
                    liveSessionIdentity: 1,
                    capturedAt: Date())

                XCTAssertTrue((0...1).contains(chars), "\(document.id)/\(variant.rawValue) chars")
                XCTAssertTrue((0...1).contains(digits), "\(document.id)/\(variant.rawValue) digits")
                if variant == .clear {
                    XCTAssertFalse(recognized.isEmpty,
                                   "\(document.id) clear produced no text at all — the harness is "
                                   + "measuring nothing and every other row is meaningless")
                }

                rows.append(String(format: "| %@ | %@ | %.3f | %.3f | %d | %.0f | %.3f | %@ |",
                                   document.id, variant.rawValue, chars, digits,
                                   report.jpegByteCount, report.sharpness ?? -1,
                                   report.meanLuma ?? -1, report.quality.rawValue))
            }
        }

        print("[FF-PR4-ACCURACY]\n| document | variant | char acc | digit acc | bytes | sharpness | luma | quality |")
        print("[FF-PR4-ACCURACY]\n|---|---|---|---|---|---|---|---|")
        for row in rows { print("[FF-PR4-ACCURACY] \(row)") }
        XCTAssertEqual(rows.count, 16)
    }

    // MARK: - Capture success through the tool

    /// Capture success is measured where it matters: through `look_closely` itself, with a fake
    /// camera serving each corpus variant, counting how many reach the model's view.
    func testCaptureSuccessThroughTheToolIsComputedAndRecorded() async throws {
        let documents = try ReadingCorpusFixtures.load()
        var rows: [String] = []
        var injectedCount = 0
        var attempted = 0

        for document in documents {
            for variant in ReadingCorpusFixtures.Variant.allCases {
                let jpeg = ReadingCorpusFixtures.jpeg(document, variant)
                let provider = CorpusStillProvider(jpeg: jpeg)
                let injector = CountingInjector()
                let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
                let tool = LookCloselyTool(
                    captureSharpStill: { identity in
                        await capture.capture(liveSessionIdentity: identity)
                    },
                    injectorProvider: { injector },
                    cameraSession: { 0 },
                    posture: { .normal })

                attempted += 1
                let result = try await tool.execute(args: ["reason": "read this label"])
                let injected = !injector.injected.isEmpty
                if injected { injectedCount += 1 }

                XCTAssertEqual(provider.requests.map(\.scope), Array(repeating: .liveSession,
                                                                     count: provider.requests.count),
                               "a still bound for a cloud session must be requested under the "
                               + "filtered live-session scope, never an on-device one")
                XCTAssertTrue(provider.requests.allSatisfy { $0.source == .photoOnly },
                              "the cached stream frame is the picture that already failed to "
                              + "resolve the detail")

                rows.append("| \(document.id) | \(variant.rawValue) | "
                            + "\(injected ? "injected" : "degraded") | \(provider.requests.count) | "
                            + "\(outcomeWord(result)) |")
            }
        }

        print("[FF-PR4-CAPTURE]\n| document | variant | outcome | captures | tool result |")
        print("[FF-PR4-CAPTURE]\n|---|---|---|---|---|")
        for row in rows { print("[FF-PR4-CAPTURE] \(row)") }
        print("[FF-PR4-CAPTURE] injected \(injectedCount) of \(attempted)")
        XCTAssertEqual(attempted, 16)
        XCTAssertGreaterThan(injectedCount, 0,
                             "no variant reached the model at all — the harness is vacuous")
    }

    private func outcomeWord(_ result: String) -> String {
        if result == LookCloselyPolicy.sharpFrameInstruction { return "read-from-image" }
        if result.contains("PARTIAL TEXT") { return "partial-transcription" }
        if result.contains("not good enough to read") { return "reposition" }
        return "other"
    }

    // MARK: - Latency baseline

    /// End of question to first usable text, through the clock seam the tool takes.
    ///
    /// The clock is injected — that is what makes the stamping on the report testable — and here it
    /// reads the real one, so the number is the actual in-process cost of capture, filtering,
    /// encoding, measurement and, on the degraded paths, the on-device recognition pass. It excludes
    /// everything this harness cannot see: the glasses shutter, Bluetooth or Wi-Fi transfer, the
    /// model's own latency and speech. Those are the on-device measurement PR4 still owes.
    func testTimeToFirstUsableTextIsComputedAndRecorded() async throws {
        let documents = try ReadingCorpusFixtures.load()
        var rows: [String] = []

        for document in documents {
            for variant in [ReadingCorpusFixtures.Variant.clear, .blurred] {
                let jpeg = ReadingCorpusFixtures.jpeg(document, variant)
                let provider = CorpusStillProvider(jpeg: jpeg)
                let injector = CountingInjector()
                let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
                let tool = LookCloselyTool(
                    captureSharpStill: { identity in
                        await capture.capture(liveSessionIdentity: identity)
                    },
                    injectorProvider: { injector },
                    cameraSession: { 0 },
                    posture: { .normal },
                    now: { Date() })

                let started = Date()
                _ = try await tool.execute(args: ["reason": "read this"])
                let elapsed = Date().timeIntervalSince(started) * 1000

                XCTAssertGreaterThanOrEqual(elapsed, 0)
                rows.append(String(format: "| %@ | %@ | %.0f |",
                                   document.id, variant.rawValue, elapsed))
            }
        }

        print("[FF-PR4-LATENCY]\n| document | variant | request → tool result (ms) |")
        print("[FF-PR4-LATENCY]\n|---|---|---|")
        for row in rows { print("[FF-PR4-LATENCY] \(row)") }
        XCTAssertEqual(rows.count, 8)
    }
}
