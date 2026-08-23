import XCTest
@testable import OpenGlasses

final class Gemma4ChatPromptTests: XCTestCase {
    func testMatchesGemma4Ids() {
        XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-4-e2b-it-4bit"))
        XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-4-E2B-it-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-3-4b-it-qat-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit"))
    }

    func testRenderSystemUser() {
        let text = Gemma4ChatPrompt.render(
            system: "You are helpful.",
            history: [],
            userMessage: "What's the quickest route to Istanbul",
            bosToken: "<bos>")
        XCTAssertEqual(
            text,
            "<bos><|turn>system\nYou are helpful.<turn|>\n<|turn>user\nWhat's the quickest route to Istanbul<turn|>\n<|turn>model\n")
    }

    func testRenderHistoryMapsAssistantToModel() {
        let text = Gemma4ChatPrompt.render(
            system: "",
            history: [
                (role: "user", content: "Hi"),
                (role: "assistant", content: "Hello"),
            ],
            userMessage: "Next",
            bosToken: nil)
        XCTAssertEqual(
            text,
            "<|turn>user\nHi<turn|>\n<|turn>model\nHello<turn|>\n<|turn>user\nNext<turn|>\n<|turn>model\n")
    }

    func testGemma4ConfigurationAddsTurnStop() {
        XCTAssertEqual(
            LocalLLMService.modelConfiguration(for: "mlx-community/gemma-4-e2b-it-4bit").extraEOSTokens,
            ["<turn|>"])
    }

    func testJinjaParserFailure() {
        struct Fake: Error { let localizedDescription: String }
        XCTAssertTrue(Gemma4ChatPrompt.isJinjaParserFailure(
            Fake(localizedDescription: #"parser("Unexpected token for primary expression: modulo")"#)))
        XCTAssertFalse(Gemma4ChatPrompt.isJinjaParserFailure(
            Fake(localizedDescription: "The glasses camera is not connected.")))
    }
}
