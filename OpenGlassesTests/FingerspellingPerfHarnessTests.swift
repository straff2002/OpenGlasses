import CoreML
import UIKit
import XCTest
@testable import OpenGlasses

/// P3 perf harness (Plan CK): measures the two heavy stages of the live pipeline against
/// the real artefacts, headlessly. Env-gated like the engine parity test — set
/// `CK_FS_MLPACKAGE` (model package path) and `CK_LANDMARKER_TASK` (holistic task path);
/// CI skips.
///
/// The decode half runs in any configuration. The landmarker half needs the MediaPipe
/// calculators (Release `-force_load`) — but note that on the 8 GB dev MacBook Air a
/// Release-configuration `xcodebuild test` reliably hangs at runner bootstrap (the same
/// abseil static-init contention that pushed force_load out of Debug), so in practice the
/// landmarker latency numbers come from the live pipeline's built-in `[CK-Perf]`
/// instrumentation during device smoke instead; this test stays for hosts/devices where
/// Release-config testing works.
///
/// Output (test log): median/p90 per-frame landmark latency, median/max per-tick decode
/// latency, and the implied comfortable frame rate + decode cadence — the numbers that
/// seed the on-device Tuning defaults.
final class FingerspellingPerfHarnessTests: XCTestCase {

    private func environmentURL(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key] else {
            throw XCTSkip("\(key) not set — perf harness runs locally against real artefacts")
        }
        return URL(fileURLWithPath: path)
    }

    private func measureMs(_ block: () throws -> Void) rethrows -> Double {
        let start = CACurrentMediaTime()
        try block()
        return (CACurrentMediaTime() - start) * 1000
    }

    private func summarize(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(Int(Double(sorted.count) * 0.9), sorted.count - 1)]
        print("[CK-P3] \(name): median \(String(format: "%.1f", median)) ms, "
              + "p90 \(String(format: "%.1f", p90)) ms, "
              + "max \(String(format: "%.1f", sorted.last ?? 0)) ms over \(samples.count) runs")
    }

    /// A camera-sized frame with enough structure that the graph does real work
    /// (gradient + blobs; without a person it reports no landmarks, which is fine —
    /// the graph still runs its detector stages every frame).
    private func syntheticFrame(seed: Int) -> UIImage {
        let size = CGSize(width: 1280, height: 720)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0.85, alpha: 1), UIColor(white: 0.35, alpha: 1)]
            colors[seed % 2].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: CGFloat(seed % 10) / 10, saturation: 0.6,
                    brightness: 0.7, alpha: 1).setFill()
            for blob in 0..<6 {
                let x = CGFloat((seed * 97 + blob * 211) % 1100)
                let y = CGFloat((seed * 61 + blob * 149) % 600)
                context.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: 140, height: 180))
            }
        }
    }

    func testLandmarkerPerFrameLatency() throws {
        let taskURL = try environmentURL("CK_LANDMARKER_TASK")
        let service: HolisticLandmarkService
        do {
            service = try HolisticLandmarkService(taskModelURL: taskURL)
        } catch {
            throw XCTSkip("landmarker unavailable (Debug link has no calculators): \(error)")
        }

        let frames = (0..<40).map(syntheticFrame(seed:))
        // Warmup: first detections page in the graph.
        for (index, frame) in frames.prefix(5).enumerated() {
            _ = try? service.holisticFrame(for: frame, timestampMilliseconds: index)
        }
        var samples: [Double] = []
        for (index, frame) in frames.dropFirst(5).enumerated() {
            let ms = measureMs {
                _ = try? service.holisticFrame(for: frame, timestampMilliseconds: 1000 + index)
            }
            samples.append(ms)
        }
        summarize("landmarker per-frame (no-person floor)", samples)
        let median = samples.sorted()[samples.count / 2]
        print("[CK-P3] implied max sustainable camera rate ≈ \(Int(1000 / max(median, 1))) fps "
              + "(simulator CPU; device numbers differ)")
    }

    func testDecodePerTickLatency() throws {
        let modelURL = try environmentURL("CK_FS_MLPACKAGE")
        let configuration = MLModelConfiguration()
        let engine = try FingerspellingInferenceEngine(modelPackageURL: modelURL,
                                                       configuration: configuration)

        // A representative mid-conversation window: 240 present frames of plausible
        // standardized values.
        var frames: [HolisticFrame] = []
        var generator = SystemRandomNumberGenerator()
        for index in 0..<240 {
            let points = (0..<HolisticLayout.landmarkCount).map { _ in
                SIMD3(x: Float.random(in: 0.2...0.8, using: &generator),
                      y: Float.random(in: 0.2...0.8, using: &generator),
                      z: Float.random(in: -0.1...0.1, using: &generator))
            }
            frames.append(HolisticFrame(timestamp: TimeInterval(index) / 15, points: points))
        }
        let input = try XCTUnwrap(HolisticWindower.modelInput(for: frames))

        _ = try engine.logits(for: input) // warmup / compile cache
        var samples: [Double] = []
        for _ in 0..<12 {
            samples.append(try measureMs { _ = try engine.logits(for: input) })
        }
        summarize("decode per-tick (240-frame window)", samples)
        let median = samples.sorted()[samples.count / 2]
        print("[CK-P3] at 15 fps, decode-every-8-frames budget is 533 ms; "
              + "median tick uses \(Int(100 * median / 533))% of it")
    }
}
