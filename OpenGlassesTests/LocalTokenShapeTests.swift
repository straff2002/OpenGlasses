import XCTest
@testable import OpenGlasses

/// Token-shape contract for on-device generation.
///
/// Text-factory models MUST receive 1D (L,) tokens: the library's default `prepare`
/// chunks prompts longer than the 512-token prefill step by slicing axis 0, so an
/// explicit (1, L) batch axis leaves an empty (0, L) remainder that fatally crashes
/// MLX in the embedding reshape — the "local Gemma crashes on any real question" bug.
/// Vision-factory models (SmolVLM2 only) skip chunked prepare and need the batch axis.
///
/// The shaping itself (`LocalLLMService.tokenBatch`) can't be exercised here: even
/// constructing an MLXArray crashes on the simulator (no MLX Metal support), so the
/// 1D-vs-2D branch is covered by the on-device path only. What IS asserted is the
/// routing input that decides the shape.
final class LocalTokenShapeTests: XCTestCase {

    func testGemma4UsesTextFactory() {
        XCTAssertFalse(LocalLLMService.visionModelIds.contains("mlx-community/gemma-4-e2b-it-4bit"))
        XCTAssertFalse(LocalLLMService.visionModelIds.contains("mlx-community/gemma-4-E2B-it-4bit"))
        XCTAssertFalse(LocalLLMService.visionModelIds.contains("mlx-community/gemma-4-e4b-it-4bit"))
        XCTAssertFalse(LocalLLMService.isVisionCapable(modelId: "mlx-community/gemma-4-e2b-it-4bit"))
    }

    func testVisionModelIdsAreVLMFactoryModels() {
        XCTAssertEqual(
            LocalLLMService.visionModelIds,
            [
                "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
                "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            ]
        )
    }
}
