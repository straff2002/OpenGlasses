import XCTest
@testable import OpenGlasses

/// Plan HR P1 items 1 and 3 — Social mode asks for what is visible, and the service never speaks an
/// answer that names a feeling. The service is driven with a fake model: no camera, no network, no
/// voice.
@MainActor
final class SocialObservationModeTests: XCTestCase {

    // MARK: - Fixtures

    /// Answers in order and records what it was asked.
    private final class FakeModel {
        var replies: [String?]
        private(set) var asked: [(systemPrompt: String, userText: String)] = []
        init(_ replies: [String?]) { self.replies = replies }

        func ask(_ systemPrompt: String, _ userText: String) -> String? {
            asked.append((systemPrompt, userText))
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

    /// Collects log lines; a tap may be called off the main thread.
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [String] = []
        func record(_ line: String) { lock.lock(); captured.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    }

    private func json(_ advice: String, urgency: String = "low", followup: String? = nil) -> String {
        var object: [String: String] = ["advice": advice, "urgency": urgency]
        if let followup { object["followup"] = followup }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private var service: AssistiveModeService { AssistiveModeService.shared }
    private var prompt: String { AssistiveRouter.systemPrompt(for: .social) }
    private var question: String { AssistiveRouter.userText(for: .social, transcription: nil) }

    private func resolve(_ mode: AssistiveRouter.Mode, _ model: FakeModel) async -> AssistiveAdvice? {
        await service.resolveAdvice(mode: mode,
                                    systemPrompt: AssistiveRouter.systemPrompt(for: mode),
                                    userText: AssistiveRouter.userText(for: mode, transcription: nil)) {
            model.ask($0, $1)
        }
    }

    // MARK: - The contract (item 1)

    func testTheSocialPromptAsksForWhatIsVisibleAndForbidsInference() {
        for cue in ["smiling", "mouth turned down", "brow raised", "eyes narrowed", "looking at you",
                    "looking away", "leaning in", "arms crossed", "stepping back", "waving you over"] {
            XCTAssertTrue(prompt.contains(cue), "the prompt should name \(cue)")
        }
        XCTAssertTrue(prompt.contains("Never name an emotion, a mood, an intention or a diagnosis"))
        XCTAssertFalse(prompt.contains("emotional state"))
        XCTAssertFalse(prompt.contains("distress"), "urgency is situational, not a band of the person's state")
        XCTAssertFalse(prompt.contains("unease"))
    }

    func testUrgencyIsRedefinedInObservableTerms() {
        XCTAssertTrue(prompt.contains("low = nothing needs a response"))
        XCTAssertTrue(prompt.contains("medium = the person is addressing you or waiting for you"))
        XCTAssertTrue(prompt.contains("high = the person is signalling urgently"))
    }

    /// The JSON contract and the spoken-output fragments ride along exactly as before.
    func testTheJSONContractAndTheSpokenOutputFragmentsAreKept() {
        XCTAssertTrue(prompt.contains(#"{"advice": string"#))
        XCTAssertTrue(prompt.contains(#""urgency": "low"|"medium"|"high""#))
        XCTAssertEqual(prompt, BlindAssistanceContract.applying(
            BlindAssistanceContract.spokenOutputFragments,
            to: prompt.components(separatedBy: "\n\n").first ?? ""),
            "the spoken-output fragments still land after the contract")
    }

    func testTheSocialQuestionAsksWhatCanBeSeen() {
        XCTAssertEqual(question,
                       "What can you see about the person I'm looking at: their expression, where they're looking, and what they're doing?")
        // A wearer who asks how someone feels still reaches Social mode, and the frame still asks
        // the observation question after their words.
        XCTAssertEqual(AssistiveRouter.route(transcription: "how is she feeling"), .social)
        let asked = AssistiveRouter.userText(for: .social, transcription: "how is she feeling")
        XCTAssertTrue(asked.hasPrefix("how is she feeling"))
        XCTAssertTrue(asked.hasSuffix(SocialObservationContract.observationQuestion))
        // Scene mode is untouched.
        XCTAssertEqual(AssistiveRouter.userText(for: .scene, transcription: "what is this"), "what is this")
    }

    func testNoWearerFacingLineNamesAPlan() {
        for line in [SocialObservationContract.fallbackLine, SocialObservationContract.observationQuestion] {
            XCTAssertFalse(line.contains("Plan"), line)
        }
        XCTAssertEqual(SocialObservationContract.fallbackLine,
                       "I can describe what I can see, not how they feel.")
    }

    // MARK: - Fail-closed in the service (item 3)

    func testAnObservationIsSpokenAsItIs() async {
        let model = FakeModel([json("Smiling and looking at you.", urgency: "medium")])
        let retries = service.socialInferenceRetries

        let advice = await resolve(.social, model)

        XCTAssertEqual(advice?.advice, "Smiling and looking at you.")
        XCTAssertEqual(advice?.urgency, .medium)
        XCTAssertEqual(model.asked.count, 1, "no re-ask when the answer is an observation")
        XCTAssertEqual(service.socialInferenceRetries, retries)
    }

    func testAnInferenceIsReAskedOnceWithTheStricterInstructionThenSpokenIfClean() async {
        let model = FakeModel([json("She looks upset."),
                               json("Mouth turned down, looking away.", followup: "Want me to keep watching?")])
        let retries = service.socialInferenceRetries
        let withheld = service.socialInferenceWithheld

        let advice = await resolve(.social, model)

        XCTAssertEqual(advice?.advice, "Mouth turned down, looking away.")
        XCTAssertEqual(model.asked.count, 2)
        XCTAssertFalse(model.asked[0].systemPrompt.contains(SocialObservationContract.retryInstruction))
        XCTAssertTrue(model.asked[1].systemPrompt.hasSuffix(SocialObservationContract.retryInstruction))
        XCTAssertTrue(model.asked[1].systemPrompt.hasPrefix(prompt), "the same prompt, made stricter")
        XCTAssertEqual(model.asked[1].userText, model.asked[0].userText, "the same question")
        XCTAssertEqual(service.socialInferenceRetries, retries + 1)
        XCTAssertEqual(service.socialInferenceWithheld, withheld)
    }

    func testASecondInferenceSpeaksTheFallbackAndNeverTheModelsWords() async {
        let model = FakeModel([json("He seems angry.", urgency: "high"),
                               json("He is frustrated and wants to leave.", urgency: "high")])
        let withheld = service.socialInferenceWithheld

        let advice = await resolve(.social, model)

        XCTAssertEqual(advice, AssistiveAdvice(advice: SocialObservationContract.fallbackLine,
                                               urgency: .low, followup: nil))
        XCTAssertEqual(model.asked.count, 2, "re-asked once, never more")
        XCTAssertEqual(service.socialInferenceWithheld, withheld + 1)
    }

    /// The counter is content-free: the log line carries the event and a count, never the words.
    func testTheWithheldCounterIsLoggedWithoutTheModelsWords() async {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }

        let model = FakeModel([json("Zorblat seems furious."), json("Zorblat looks anxious.")])
        _ = await resolve(.social, model)
        PrivacyLog.removeTap(tap)
        let lines = sink.lines

        let retried = lines.filter { $0.contains("inferenceRetried") }
        let withheld = lines.filter { $0.contains("inferenceWithheld") }
        XCTAssertEqual(retried.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(withheld.count, 1, lines.joined(separator: "\n"))
        for line in lines {
            XCTAssertFalse(line.contains("Zorblat"), "the model's words reached the log: \(line)")
            XCTAssertFalse(line.contains("furious") || line.contains("anxious"), line)
        }
    }

    func testAnUnparseableReAskSpeaksNothing() async {
        let model = FakeModel([json("She looks happy."), "not json at all"])
        let advice = await resolve(.social, model)
        XCTAssertNil(advice, "fail closed: neither the inference nor a guess is spoken")
        XCTAssertEqual(model.asked.count, 2)
    }

    /// Scene mode is untouched: no filter, no re-ask, even on words the filter would catch.
    func testSceneModeIsNotFiltered() async {
        let model = FakeModel([json("A calm, quiet waiting room; the exit is ahead.")])
        let retries = service.socialInferenceRetries

        let advice = await resolve(.scene, model)

        XCTAssertEqual(advice?.advice, "A calm, quiet waiting room; the exit is ahead.")
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(service.socialInferenceRetries, retries)
    }
}
