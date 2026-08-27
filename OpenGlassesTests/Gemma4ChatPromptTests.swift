import XCTest
@testable import OpenGlasses

/// Gemma 4's prompt format, its stop token, and the device tiering around a photo turn.
///
/// All of it is deliberately pure: the model itself is multi-gigabyte and MLX has no Metal on
/// the simulator, so what is testable here is the *contract* the on-device path depends on —
/// what the rendered turn looks like, what counts as a template-parse failure, and how much of
/// a turn a given phone is allowed to carry.
final class Gemma4ChatPromptTests: XCTestCase {

    // MARK: - Model id matching

    func testMatchesGemma4Ids() {
        XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-4-e2b-it-4bit"))
        // The community page uses a capital E for the E-series; the catalog uses lowercase.
        XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-4-E2B-it-4bit"))
        XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-4-e4b-it-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-3-4b-it-qat-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: "mlx-community/gemma-2-2b-it-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit"))
        XCTAssertFalse(Gemma4ChatPrompt.matches(modelId: nil))
    }

    /// Every Gemma 4 id the catalog offers must take the Gemma path, or a checkpoint would load
    /// with the wrong stop token and run past the end of its answer.
    @MainActor
    func testEveryCatalogGemma4TakesTheGemmaPath() {
        let gemmaIds = LocalLLMService.recommendedModels
            .map(\.id)
            .filter { $0.lowercased().contains("gemma-4") }
        XCTAssertFalse(gemmaIds.isEmpty, "catalog should still offer Gemma 4")
        for id in gemmaIds {
            XCTAssertTrue(Gemma4ChatPrompt.matches(modelId: id), id)
        }
    }

    // MARK: - Rendering

    func testRenderSystemUser() {
        let text = Gemma4ChatPrompt.render(
            system: "You are helpful.",
            history: [],
            userMessage: "What's the quickest route to Istanbul",
            bosToken: "<bos>")
        XCTAssertEqual(
            text,
            "<bos><|turn>system\nYou are helpful.<turn|>\n"
            + "<|turn>user\nWhat's the quickest route to Istanbul<turn|>\n"
            + "<|turn>model\n")
    }

    /// The system prompt is a genuine system TURN, exactly as `chat_template.jinja` emits it —
    /// not merged into the first user turn. Merging is the role-flip hazard: the model reads a
    /// persona description as something the wearer said and answers in the wearer's voice.
    func testSystemPromptIsItsOwnTurnNotMergedIntoTheUserTurn() {
        let text = Gemma4ChatPrompt.render(
            system: "You are OpenGlasses.",
            history: [],
            userMessage: "Hello",
            bosToken: nil)
        XCTAssertTrue(text.hasPrefix("<|turn>system\nYou are OpenGlasses.<turn|>\n"))
        XCTAssertFalse(text.contains("You are OpenGlasses.\n\nHello"))
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

    /// An empty system prompt emits no system turn at all (the template only opens one when
    /// message 0 is a system message), and the BOS token is omitted when the tokenizer has none.
    func testEmptySystemAndNoBosProduceNoScaffolding() {
        let text = Gemma4ChatPrompt.render(
            system: "   \n  ", history: [], userMessage: "Hi", bosToken: nil)
        XCTAssertEqual(text, "<|turn>user\nHi<turn|>\n<|turn>model\n")
    }

    /// No "User:"/"Assistant:" transcript labels anywhere — a small model reading a labelled
    /// dialogue can flip roles and reply *as* the wearer.
    func testRenderUsesNoSpeakerLabels() {
        let text = Gemma4ChatPrompt.render(
            system: "Persona.",
            history: [(role: "user", content: "Hi"), (role: "assistant", content: "Hello")],
            userMessage: "Next",
            bosToken: "<bos>")
        XCTAssertFalse(text.contains("User:"))
        XCTAssertFalse(text.contains("Assistant:"))
        XCTAssertFalse(text.contains("Model:"))
    }

    /// The render always ends on the generation prompt, so the model continues rather than
    /// opening a turn of its own.
    func testRenderEndsOnTheGenerationPrompt() {
        let text = Gemma4ChatPrompt.render(
            system: "S", history: [], userMessage: "U", bosToken: nil)
        XCTAssertTrue(text.hasSuffix("<|turn>model\n"))
    }

    // MARK: - Stop token

    /// `<turn|>` is the checkpoint's `eot_token`, and its `eos_token` is the different `<eos>` —
    /// so it has to be declared explicitly or generation runs past the end of the answer.
    func testGemma4ConfigurationAddsTurnStop() {
        XCTAssertEqual(
            LocalLLMService.modelConfiguration(for: "mlx-community/gemma-4-e2b-it-4bit").extraEOSTokens,
            ["<turn|>"])
        XCTAssertEqual(Gemma4ChatPrompt.endOfTurnToken, "<turn|>")
    }

    func testNonGemmaConfigurationAddsNoExtraStops() {
        XCTAssertTrue(
            LocalLLMService.modelConfiguration(for: "mlx-community/Qwen2.5-3B-Instruct-4bit")
                .extraEOSTokens.isEmpty)
        XCTAssertTrue(
            LocalLLMService.modelConfiguration(for: "mlx-community/SmolVLM2-2.2B-Instruct-mlx")
                .extraEOSTokens.isEmpty)
    }

    // MARK: - Template parse failure

    /// The Jinja error type isn't in this target's dependency surface, so the classifier reads
    /// the error's description. These fixtures reproduce the two shapes seen from Gemma 4's
    /// template; anything else must fall through to the ordinary no-system-role repair.
    func testTemplateParseFailureRecognisesJinjaShapesOnly() {
        struct DescribedError: Error, CustomStringConvertible { let description: String }

        XCTAssertTrue(Gemma4ChatPrompt.isTemplateParseFailure(
            DescribedError(description: #"parser("Unexpected token for primary expression: modulo")"#)))
        XCTAssertTrue(Gemma4ChatPrompt.isTemplateParseFailure(
            DescribedError(description: "Unexpected token for primary expression: modulo")))
        XCTAssertFalse(Gemma4ChatPrompt.isTemplateParseFailure(
            DescribedError(description: "The glasses camera is not connected.")))
        XCTAssertFalse(Gemma4ChatPrompt.isTemplateParseFailure(
            LocalLLMError.modelNotLoaded))
        // A "no system role" template failure must NOT be mistaken for a parse failure — those
        // models want the merge repair, not Gemma's turn format.
        XCTAssertFalse(Gemma4ChatPrompt.isTemplateParseFailure(
            DescribedError(description: "chatTemplate(\"System role not supported\")")))
    }

    // MARK: - Device tiering for a photo turn

    /// A roomy phone keeps its configured prompt and its history: the memory workaround is a
    /// small-device workaround, and charging a 12 GB phone for an 8 GB phone's problem costs
    /// persona, tools and context for nothing.
    func testRoomyDeviceKeepsTheWholeMultimodalTurn() {
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: "mlx-community/gemma-4-e2b-it-4bit", marketingRAMGB: 12)
        XCTAssertTrue(plan.keepsFullSystemPrompt)
        XCTAssertTrue(plan.keepsHistory)
        XCTAssertEqual(plan.promptBudget,
                       LocalModelBudget.promptBudget(for: "mlx-community/gemma-4-e2b-it-4bit"))
    }

    func testConstrainedDeviceTrimsTheMultimodalTurn() {
        let id = "mlx-community/gemma-4-e2b-it-4bit"
        let plan = LocalModelBudget.multimodalTurnPlan(for: id, marketingRAMGB: 8)
        XCTAssertFalse(plan.keepsFullSystemPrompt)
        XCTAssertFalse(plan.keepsHistory)
        XCTAssertLessThan(plan.promptBudget, LocalModelBudget.promptBudget(for: id))
        XCTAssertGreaterThanOrEqual(plan.promptBudget, LocalModelBudget.minimumBudget)
    }

    // MARK: - Headroom, not marketing RAM

    private static let gemma = "mlx-community/gemma-4-e2b-it-4bit"
    private static let gigabyte: Int64 = 1_073_741_824

    /// The device kill this gate exists for: a 12 GB iPhone on the roomy tier, Gemma resident and
    /// the camera live, taken to a 6.2 GB footprint by a photo turn and terminated for exceeding
    /// the *per-process* limit while frontmost. Marketing RAM said "roomy" the whole way down.
    func testTheMeasuredCrashScenarioIsRefusedNotAttempted() {
        // ~0.3 GB left to allocate on a 12 GB phone at the moment the photo turn began.
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: Self.gemma, marketingRAMGB: 12, availableBytes: Int64(0.3 * Double(Self.gigabyte)))
        XCTAssertTrue(plan.refusesImage,
                      "a turn with no headroom must be refused out loud, never attempted")
    }

    func testARoomyDeviceRunningLowIsTreatedAsConstrained() {
        // Headroom leads: 12 GB on the box, 1.5 GB left in the process — that is the small-device
        // case, and it gets the small-device plan rather than the full prompt and history.
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: Self.gemma, marketingRAMGB: 12, availableBytes: Int64(1.5 * Double(Self.gigabyte)))
        XCTAssertFalse(plan.refusesImage)
        XCTAssertFalse(plan.keepsHistory)
        XCTAssertFalse(plan.keepsFullSystemPrompt)
        XCTAssertEqual(plan.imageLongEdge, LocalModelBudget.constrainedImageLongEdge)
    }

    func testARoomyDeviceWithRealHeadroomKeepsTheWholeTurn() {
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: Self.gemma, marketingRAMGB: 12, availableBytes: 4 * Self.gigabyte)
        XCTAssertFalse(plan.refusesImage)
        XCTAssertTrue(plan.keepsHistory)
        XCTAssertTrue(plan.keepsFullSystemPrompt)
        XCTAssertEqual(plan.imageLongEdge, LocalModelBudget.fullImageLongEdge)
    }

    func testUnknownHeadroomSkipsTheGateRatherThanRefusing() {
        // `os_proc_available_memory()` returns 0 where no per-process budget applies (simulator,
        // Mac). Refusing on unknown would brick exactly the environments that don't need this.
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: Self.gemma, marketingRAMGB: 12, availableBytes: 0)
        XCTAssertFalse(plan.refusesImage)
        XCTAssertTrue(plan.keepsHistory)
    }

    func testASmallDeviceWithHeadroomIsStillTrimmedNotRefused() {
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: Self.gemma, marketingRAMGB: 8, availableBytes: 4 * Self.gigabyte)
        XCTAssertFalse(plan.refusesImage)
        XCTAssertFalse(plan.keepsHistory)
        XCTAssertEqual(plan.imageLongEdge, LocalModelBudget.constrainedImageLongEdge)
    }

    // MARK: - Bounding the image itself

    func testAFullResolutionPhotoIsBoundedWithItsAspectKept() {
        // A glasses frame, not a square: squashing it to 896² was the old cap's cost, and having
        // no cap at all was the memory spike that replaced it.
        let size = LocalModelBudget.imageSize(width: 4032, height: 3024, maxLongEdge: 1344)
        XCTAssertEqual(size?.width, 1344)
        XCTAssertEqual(size?.height, 1008)
    }

    func testAPortraitPhotoIsBoundedOnItsLongEdge() {
        let size = LocalModelBudget.imageSize(width: 1080, height: 1920, maxLongEdge: 896)
        XCTAssertEqual(size?.height, 896)
        XCTAssertEqual(size?.width, 504)
    }

    func testAnImageAlreadyWithinBudgetIsNotResampled() {
        // Re-sampling a small image spends memory to change nothing, which is the opposite of
        // what this is for.
        XCTAssertNil(LocalModelBudget.imageSize(width: 640, height: 480, maxLongEdge: 1344))
    }

    func testDegenerateSizesAreLeftAlone() {
        XCTAssertNil(LocalModelBudget.imageSize(width: 0, height: 0, maxLongEdge: 1344))
        XCTAssertNil(LocalModelBudget.imageSize(width: 4032, height: 3024, maxLongEdge: 0))
    }

    /// Text turns are unaffected by the tiering — their prefill is chunked, so a fat prompt
    /// costs time rather than a resident-memory spike.
    func testTextBudgetIsUnchangedByDeviceRAM() {
        let id = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertEqual(LocalModelBudget.promptBudget(for: id), 4096 - 512 - 128)
    }

    // MARK: - Compact photo-turn prompt

    /// The reduced prompt is derived, not hardcoded: the configured prompt's identity line
    /// survives, so a custom persona isn't silently replaced on every photo question.
    func testCompactVisionPromptKeepsThePersonaLine() {
        let configured = """
        You are Ada, a birding assistant on smart glasses.

        RESPONSE STYLE:
        - Be brief.
        """
        let compact = Config.compactVisionTurnPrompt(from: configured, languageCode: "en")
        XCTAssertTrue(compact.hasPrefix("You are Ada, a birding assistant on smart glasses."))
        XCTAssertTrue(compact.contains("You CAN see it"))
        XCTAssertLessThan(compact.count, configured.count + 400)
        XCTAssertFalse(compact.contains("RESPONSE STYLE"))
    }

    /// A non-English wearer keeps their language. The old shape of this fix replaced the whole
    /// prompt with an English literal, which silently switched them to English on every photo.
    func testCompactVisionPromptNamesTheWearersLanguage() {
        let compact = Config.compactVisionTurnPrompt(from: "You are OpenGlasses.", languageCode: "ja")
        XCTAssertTrue(compact.contains("Answer in Japanese."), compact)
    }

    func testCompactVisionPromptOmitsTheLanguageLineForEnglish() {
        let compact = Config.compactVisionTurnPrompt(from: "You are OpenGlasses.", languageCode: "en")
        XCTAssertFalse(compact.contains("Answer in English."))
        XCTAssertNil(Config.spokenLanguageName(for: "en"))
    }

    func testCompactVisionPromptSurvivesAnEmptySystemPrompt() {
        let compact = Config.compactVisionTurnPrompt(from: "", languageCode: "en")
        XCTAssertFalse(compact.isEmpty)
        XCTAssertTrue(compact.contains("You CAN see it"))
    }
}
