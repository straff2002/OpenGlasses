import CoreML
import XCTest
@testable import OpenGlasses

/// Integration test for the Core ML engine (Plan CK P2). The model artefact is not
/// published (and not committed), so this runs only when `CK_FS_MLPACKAGE` points at a
/// local `Fingerspelling2P.mlpackage` — the standing local gate before a release touches
/// the fingerspelling path; CI skips it. With the artefact present, the full Swift
/// pipeline (fixture raw landmarks → `HolisticWindower` → engine → decode) must reproduce
/// the Python reference: fp16-scale tolerance on logits, exact decode.
final class FingerspellingInferenceEngineTests: XCTestCase {

    private struct Fixture: Decodable {
        var processedFrameCount: Int
        var rawFrameCount: Int
        var raw: String
        var logits: String
        var decoded: String
    }

    private func requireModelURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CK_FS_MLPACKAGE"] else {
            throw XCTSkip("CK_FS_MLPACKAGE not set — model artefact not available")
        }
        return URL(fileURLWithPath: path)
    }

    private func floats(_ base64: String) throws -> [Float] {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func fixture(_ name: String) throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: FingerspellingInferenceEngineTests.self)
                .url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEngineReproducesReferenceLogitsAndDecode() throws {
        let modelURL = try requireModelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly // deterministic vs the Python reference run
        let engine = try FingerspellingInferenceEngine(modelPackageURL: modelURL,
                                                       configuration: configuration)

        for name in ["fingerspelling_plain", "fingerspelling_left_handed"] {
            let fixture = try fixture(name)

            let values = try floats(fixture.raw)
            let perFrame = HolisticLayout.featuresPerFrame
            let frames = (0..<fixture.rawFrameCount).map { frameIndex -> HolisticFrame in
                let base = frameIndex * perFrame
                let points = (0..<HolisticLayout.landmarkCount).map {
                    SIMD3(x: values[base + $0 * 3], y: values[base + $0 * 3 + 1],
                          z: values[base + $0 * 3 + 2])
                }
                return HolisticFrame(timestamp: TimeInterval(frameIndex) / 30, points: points)
            }

            let input = try XCTUnwrap(HolisticWindower.modelInput(for: frames))
            XCTAssertEqual(input.frameCount, fixture.processedFrameCount)

            let rows = try engine.logits(for: input)
            let validRows = Array(rows.prefix((input.frameCount + 1) / 2))

            let expected = try floats(fixture.logits)
            XCTAssertEqual(expected.count, validRows.count * 62, "fixture/engine row mismatch")
            var maxDifference: Float = 0
            for (rowIndex, row) in validRows.enumerated() {
                for (classIndex, value) in row.enumerated() {
                    maxDifference = max(maxDifference,
                                        abs(value - expected[rowIndex * 62 + classIndex]))
                }
            }
            XCTAssertLessThan(maxDifference, 0.5,
                              "\(name): logits diverge beyond fp16-scale tolerance")

            XCTAssertEqual(FingerspellingCTCDecoder.decode(logitRows: validRows),
                           fixture.decoded, "\(name): decode must match the reference exactly")
        }
    }
}
