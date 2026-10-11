import XCTest
import UIKit
@testable import OpenGlasses

/// Exercise the real photo dispatcher over a recording transport, with a local model and
/// Claude available after a local model in saved order. A capable selection leads; cloud
/// vision must serve an unsupported selection before the automatic local fallback.
@MainActor
final class SelectedPhotoModelTests: XCTestCase {
    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var cascade = false
    private var hipaa = false
    private var localOnly = false
    private var agent = false
    private var dailyCap: Double = 0
    private var monthlyCap: Double = 0

    override func setUp() {
        super.setUp()
        savedModels = Config.savedModels
        activeID = Config.activeModelId
        cascade = Config.modelCascadeEnabled
        hipaa = Config.hipaaMode
        localOnly = Config.hipaaLocalOnly
        agent = Config.agentModeEnabled
        dailyCap = Config.dailySpendCapUSD
        monthlyCap = Config.monthlySpendCapUSD
        Config.modelCascadeEnabled = true
        Config.hipaaMode = false
        Config.hipaaLocalOnly = false
        Config.setAgentModeEnabled(false)
        Config.dailySpendCapUSD = 0
        Config.monthlySpendCapUSD = 0
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.modelCascadeEnabled = cascade
        Config.hipaaMode = hipaa
        Config.hipaaLocalOnly = localOnly
        Config.setAgentModeEnabled(agent)
        Config.dailySpendCapUSD = dailyCap
        Config.monthlySpendCapUSD = monthlyCap
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func select(provider: LLMProvider = .openai, vision: Bool = true) {
        Config.setSavedModels([
            ModelConfig(id: "selected", name: "Selected", provider: provider.rawValue,
                        apiKey: "test", model: "selected-vision-model",
                        baseURL: "https://selected.example.test/v1", supportsVision: vision,
                        smallContext: true),
            ModelConfig(id: "local", name: "Local", provider: LLMProvider.local.rawValue,
                        apiKey: "", model: "mlx-community/gemma-4-E2B-it-4bit", baseURL: "",
                        supportsVision: true),
            ModelConfig(id: "claude", name: "Claude", provider: LLMProvider.anthropic.rawValue,
                        apiKey: "test", model: "claude-sonnet-4-6",
                        baseURL: LLMProvider.anthropic.defaultBaseURL, supportsVision: true,
                        smallContext: true)
        ])
        Config.setActiveModelId("selected")
        XCTAssertEqual(Config.activeModelId, "selected")
    }

    private func service() -> LLMService {
        let service = LLMService()
        let session = RecordingQueueProtocol.session()
        service.dataSession = session
        service.streamingSession = session
        return service
    }

    private var photo: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 0.8)!
    }

    func testPhotoRequestCarriesImageAndSelectedModelToSelectedEndpoint() async throws {
        select()
        RecordingQueueProtocol.queue = [(200, #"{"choices":[{"message":{"role":"assistant","content":"A blue image."}}]}"#)]
        var switches = 0
        let reply = try await service().sendMessageCascading("Describe this", imageData: photo,
            onModelSwitch: { _, _, _ in switches += 1 })
        XCTAssertEqual(reply, "A blue image.")
        XCTAssertEqual(switches, 0)
        let request = try XCTUnwrap(RecordingQueueProtocol.requests.first)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertTrue(request.url.hasPrefix("https://selected.example.test/"))
        XCTAssertEqual(request.json?["model"] as? String, "selected-vision-model")
        let messages = request.json?["messages"] as? [[String: Any]] ?? []
        let parts = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let imageURL = parts.first { $0["type"] as? String == "image_url" }?["image_url"] as? [String: Any]
        XCTAssertTrue((imageURL?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(Config.activeModelId, "selected")
    }

    private var claudeAnswer: String {
        #"{"content":[{"type":"text","text":"A blue image."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":4}}"#
    }

    private func assertClaudePhoto(_ request: RecordingQueueProtocol.Recorded,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.url, LLMProvider.anthropic.defaultBaseURL, file: file, line: line)
        XCTAssertEqual(request.json?["model"] as? String, "claude-sonnet-4-6", file: file, line: line)
        let messages = request.json?["messages"] as? [[String: Any]] ?? []
        let parts = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let source = parts.first { $0["type"] as? String == "image" }?["source"] as? [String: Any]
        XCTAssertEqual(source?["media_type"] as? String, "image/jpeg", file: file, line: line)
        XCTAssertFalse((source?["data"] as? String ?? "").isEmpty, file: file, line: line)
    }

    func testPhotoAuthenticationFailureTriesClaudeBeforeLocal() async throws {
        select()
        RecordingQueueProtocol.queue = [(401, #"{"error":{"message":"test refusal"}}"#), (200, claudeAnswer)]
        var switches = 0
        let reply = try await service().sendMessageCascading("Describe this", imageData: photo,
            onModelSwitch: { _, to, _ in
                XCTAssertEqual(to?.id, "claude")
                switches += 1
            })
        XCTAssertEqual(reply, "A blue image.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
        assertClaudePhoto(try XCTUnwrap(RecordingQueueProtocol.requests.last))
        XCTAssertEqual(switches, 1)
        XCTAssertEqual(Config.activeModelId, "selected")
    }

    func testChatGPTSubscriptionPhotoGoesToClaudeEvenWithVisionOverride() async throws {
        for vision in [false, true] {
            select(provider: .chatgpt, vision: vision)
            XCTAssertTrue(Config.hasVisionCapableModel, "photo controls remain available through Claude")
            RecordingQueueProtocol.reset()
            RecordingQueueProtocol.queue = [(200, claudeAnswer)]
            var switches = 0
            let reply = try await service().sendMessageCascading("Describe this", imageData: photo,
                onModelSwitch: { from, to, failure in
                    XCTAssertEqual(from?.id, "selected")
                    XCTAssertEqual(to?.id, "claude")
                    XCTAssertEqual(failure, .visionUnavailable)
                    switches += 1
                })
            XCTAssertEqual(reply, "A blue image.")
            XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
            assertClaudePhoto(try XCTUnwrap(RecordingQueueProtocol.requests.first))
            XCTAssertEqual(switches, 1, "the initial capability switch must be announced")
            XCTAssertEqual(Config.activeModelId, "selected", "restore ChatGPT for subsequent text turns")
        }
    }

    func testVisionFallbackWorksWhenTextCascadeIsDisabled() async throws {
        select(vision: false)
        Config.modelCascadeEnabled = false
        RecordingQueueProtocol.queue = [(200, claudeAnswer)]
        let reply = try await service().sendMessageCascading("Describe this", imageData: photo)
        XCTAssertEqual(reply, "A blue image.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        assertClaudePhoto(try XCTUnwrap(RecordingQueueProtocol.requests.first))
    }

    func testNoVisionCandidateReportsReasonWithoutSendingTextOnly() async {
        select(vision: false)
        Config.setSavedModels(Array(Config.savedModels.prefix(1)))
        XCTAssertFalse(Config.hasVisionCapableModel)
        do {
            _ = try await service().sendMessageCascading("Describe this", imageData: photo)
            XCTFail("must report that no vision model exists")
        } catch let LLMError.missingAPIKey(message) {
            XCTAssertTrue(message.contains("vision-capable"))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
        XCTAssertEqual(Config.activeModelId, "selected")
    }
}
