import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR8 — the processing summary.
///
/// The gate these tests hold is a single sentence: **nothing is called fully on-device unless
/// every active row is on-device and its assets are present.** Every mixed case below is here
/// because it is a configuration someone could reasonably believe is local, and the summary's
/// whole value is refusing to agree with them.
@MainActor
final class ProcessingSummaryTests: XCTestCase {

    private func destination(_ composed: ProcessingSummary.Composed,
                             _ kind: ProcessingRowKind) -> ProcessingDestination? {
        composed.rows.first { $0.kind == kind }?.destination
    }

    // MARK: - Mixed, named as mixed

    func testLocalAIWithCloudSpeechIsMixedAndNamesTheRows() {
        let facts = ProcessingFacts(
            voiceEngine: .elevenLabs,
            modelKind: .onDevice,
            modelProviderName: "Local (On-Device MLX)",
            modelAssetName: "Gemma 3n E2B",
            modelAssetPresent: true,
            speechRecognitionOnDevice: false,
            speechRecognitionProviderName: "Apple's speech recognition",
            kokoroInstalled: true)

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(composed.verdict.token, "mixed")
        guard case .mixed(let rows) = composed.verdict else { return XCTFail("not mixed") }
        XCTAssertEqual(Set(rows), [.transcription, .spokenVoice])
        XCTAssertEqual(destination(composed, .aiResponse), .onDevice)
        XCTAssertEqual(destination(composed, .image), .onDevice)
        XCTAssertTrue(composed.spoken.hasPrefix("This is a mixed setup."), composed.spoken)
        XCTAssertFalse(composed.spoken.lowercased().contains("fully on"), composed.spoken)
    }

    func testCloudAIWithLocalSpeechIsAlsoMixed() {
        let facts = ProcessingFacts(
            voiceEngine: .kokoro,
            modelKind: .cloud,
            modelProviderName: "Anthropic (Claude)",
            speechRecognitionOnDevice: true,
            kokoroInstalled: true)

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(composed.verdict.token, "mixed")
        XCTAssertEqual(destination(composed, .aiResponse), .cloud(provider: "Anthropic (Claude)"))
        XCTAssertEqual(destination(composed, .transcription), .onDevice)
        XCTAssertEqual(destination(composed, .spokenVoice), .onDevice)
    }

    // MARK: - Fully on-device

    func testEverythingOnDeviceWithItsAssetsPresentIsFullyOnDevice() {
        let facts = ProcessingFacts(
            voiceEngine: .kokoro,
            modelKind: .onDevice,
            modelProviderName: "Local (On-Device MLX)",
            modelAssetName: "Gemma 3n E2B",
            modelAssetPresent: true,
            speechRecognitionOnDevice: true,
            speechRecognitionAssetPresent: true,
            kokoroInstalled: true,
            remoteToolsEnabled: false)

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(composed.verdict, .fullyOnDevice)
        XCTAssertNil(composed.offlineLine, "nothing is missing, so nothing is owed")
        XCTAssertEqual(destination(composed, .remoteTools), .disabled)
    }

    // MARK: - Missing assets

    /// The case the whole "and its assets are present" clause exists for.
    func testAnOnDeviceModelThatIsNotDownloadedIsUnavailableAndNamedInTheOfflineLine() {
        let facts = ProcessingFacts(
            voiceEngine: .kokoro,
            modelKind: .onDevice,
            modelProviderName: "Local (On-Device MLX)",
            modelAssetName: "Gemma 3n E2B",
            modelAssetPresent: false,
            speechRecognitionOnDevice: true,
            speechRecognitionAssetPresent: true,
            kokoroInstalled: true)

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(destination(composed, .aiResponse),
                       .unavailable(missingAsset: "Gemma 3n E2B"))
        XCTAssertNotEqual(composed.verdict, .fullyOnDevice,
                          "a model that is not downloaded cannot make a setup fully on-device")
        XCTAssertEqual(composed.verdict.token, "mixed")
        XCTAssertEqual(composed.offlineLine,
                       "Before you can use this offline, download Gemma 3n E2B.")
        // And the mixed sentence must not claim it leaves the device — it sends nothing at all.
        let sentence = ProcessingSummary.verdictSentence(composed.verdict, rows: composed.rows)
        XCTAssertTrue(sentence.contains("aren't downloaded") || sentence.contains("isn't downloaded"),
                      sentence)
    }

    /// The other way to be short of an asset: a row that currently goes to the cloud with no local
    /// alternative installed to fall back to.
    func testACloudVoiceWithNoOnDeviceVoiceInstalledIsNamedInTheOfflineLine() {
        let facts = ProcessingFacts(
            voiceEngine: .elevenLabs,
            modelKind: .onDevice,
            modelAssetName: "Gemma 3n E2B",
            modelAssetPresent: true,
            speechRecognitionOnDevice: true,
            speechRecognitionAssetPresent: true,
            kokoroInstalled: false,
            kokoroAssetName: "the on-device voice")

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(composed.offlineLine,
                       "Before you can use this offline, download the on-device voice.")
    }

    // MARK: - Custom endpoints

    /// A base URL can carry a path, a query and a key. This line is read aloud, so only the host
    /// may ever reach it.
    func testACustomEndpointReportsTheHostAndNeverThePathOrTheQuery() {
        let facts = ProcessingFacts(
            modelKind: .customEndpoint,
            modelProviderName: "Custom (OpenAI-compatible)",
            modelHost: ProcessingFacts.host(of: "https://llm.example.net:8443/v1/chat/completions?api_key=sk-secret-value"))

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(destination(composed, .aiResponse),
                       .customEndpoint(host: "llm.example.net:8443"))
        for forbidden in ["sk-secret-value", "api_key", "/v1/", "chat/completions"] {
            XCTAssertFalse(composed.spoken.contains(forbidden),
                           "the spoken summary leaked \(forbidden)")
        }
    }

    func testHostReductionDropsCredentialsAndPathsInEveryShape() {
        XCTAssertEqual(ProcessingFacts.host(of: "https://user:pass@api.example.com/v1"),
                       "api.example.com")
        XCTAssertEqual(ProcessingFacts.host(of: "http://192.168.1.40:18789/invoke"),
                       "192.168.1.40:18789")
        // A hand-typed bare host, which `URLComponents` would otherwise read as a path.
        XCTAssertEqual(ProcessingFacts.host(of: "mac-mini.local"), "mac-mini.local")
        XCTAssertNil(ProcessingFacts.host(of: "   "))
    }

    // MARK: - Recomputation

    /// The summary has to follow a provider change, or it becomes a screenshot of a setup the
    /// wearer has already left.
    func testChangingTheProviderRecomputesTheSummary() {
        var facts = ProcessingFacts(modelKind: .onDevice,
                                    modelProviderName: "Local (On-Device MLX)",
                                    modelAssetName: "Gemma 3n E2B",
                                    modelAssetPresent: true,
                                    speechRecognitionOnDevice: true,
                                    kokoroInstalled: true,
                                    remoteToolsEnabled: false)
        facts.voiceEngine = .kokoro
        let model = ProcessingSummaryModel { facts }
        XCTAssertEqual(model.summary.verdict, .fullyOnDevice)

        facts.modelKind = .cloud
        facts.modelProviderName = "OpenAI (GPT)"
        // The real trigger: any settings write posts this, and every key the summary reads is a
        // defaults key.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        model.refresh()

        XCTAssertEqual(model.summary.verdict.token, "mixed")
        XCTAssertEqual(destination(model.summary, .aiResponse), .cloud(provider: "OpenAI (GPT)"))
    }

    // MARK: - Medical local-only

    func testMedicalLocalOnlyMakesEveryCloudRowReadAsDisabled() {
        let facts = ProcessingFacts(
            voiceEngine: .elevenLabs,
            modelKind: .cloud,
            modelProviderName: "Anthropic (Claude)",
            speechRecognitionOnDevice: false,
            diarizationEnabled: true,
            diarizationProviderName: "Deepgram",
            remoteToolsEnabled: true,
            remoteToolHost: "mac-mini.local",
            medicalLocalOnly: true)

        let composed = ProcessingSummary.compose(facts: facts)

        for kind in ProcessingRowKind.allCases {
            XCTAssertEqual(destination(composed, kind), .disabled,
                           "\(kind) should be stopped by the local-only rule, not rerouted")
        }
        XCTAssertFalse(composed.spoken.contains("Deepgram"), composed.spoken)
        XCTAssertFalse(composed.spoken.contains("mac-mini.local"), composed.spoken)
        // And it must not claim a setup that handles nothing is handling it all locally.
        XCTAssertTrue(composed.spoken.hasPrefix("Nothing that would leave this device is switched on."),
                      composed.spoken)
    }

    // MARK: - Live modes

    func testGeminiLiveNamesTheProviderOnTheImageAndTranscriptionRows() {
        let facts = ProcessingFacts(liveProviderName: "Google (Gemini Live)",
                                    modelKind: .onDevice,
                                    modelAssetPresent: true)

        let composed = ProcessingSummary.compose(facts: facts)

        XCTAssertEqual(destination(composed, .image), .cloud(provider: "Google (Gemini Live)"))
        XCTAssertEqual(destination(composed, .transcription),
                       .cloud(provider: "Google (Gemini Live)"))
        XCTAssertEqual(destination(composed, .aiResponse),
                       .cloud(provider: "Google (Gemini Live)"))
        // The session speaks with the provider's own voice; the configured engine is not in that
        // path, and saying otherwise would be the kind of quiet untruth this screen exists to stop.
        XCTAssertEqual(destination(composed, .spokenVoice),
                       .cloud(provider: "Google (Gemini Live)"))
        XCTAssertEqual(composed.verdict.token, "cloud")
    }

    func testOpenAIRealtimeNamesItsOwnProvider() {
        let facts = ProcessingFacts(liveProviderName: "OpenAI (Realtime)")
        let composed = ProcessingSummary.compose(facts: facts)
        XCTAssertEqual(destination(composed, .image), .cloud(provider: "OpenAI (Realtime)"))
    }

    // MARK: - Remote tools

    func testRemoteToolsOffReadAsDisabled() {
        let composed = ProcessingSummary.compose(facts: ProcessingFacts(remoteToolsEnabled: false))
        XCTAssertEqual(destination(composed, .remoteTools), .disabled)
        XCTAssertTrue(composed.rows.first { $0.kind == .remoteTools }?
            .spokenForm.contains("switched off") == true)
    }

    func testRemoteToolsOnReportTheGatewayHostOnly() {
        let facts = ProcessingFacts(remoteToolsEnabled: true,
                                    remoteToolHost: "gateway.example.ts.net")
        let composed = ProcessingSummary.compose(facts: facts)
        XCTAssertEqual(destination(composed, .remoteTools),
                       .customEndpoint(host: "gateway.example.ts.net"))
    }

    // MARK: - Images

    func testAModelThatCannotTakeImagesLeavesTheImageRowSwitchedOff() {
        let facts = ProcessingFacts(modelKind: .cloud,
                                    modelProviderName: "Groq",
                                    modelAcceptsImages: false)
        let composed = ProcessingSummary.compose(facts: facts)
        XCTAssertEqual(destination(composed, .image), .disabled)
    }

    // MARK: - Diarization

    func testDiarizationSendsTranscriptionToItsVendor() {
        let facts = ProcessingFacts(speechRecognitionOnDevice: true,
                                    diarizationEnabled: true,
                                    diarizationProviderName: "Deepgram")
        let composed = ProcessingSummary.compose(facts: facts)
        XCTAssertEqual(destination(composed, .transcription), .cloud(provider: "Deepgram"))
    }

    // MARK: - The caveat

    /// Two surfaces read this. Both have to say what the summary is not, and the spoken form has
    /// to carry it too — a wearer who only ever hears it must hear the caveat as well.
    func testTheSpokenSummaryAlwaysEndsWithTheEvidenceCaveat() {
        let composed = ProcessingSummary.compose(facts: ProcessingFacts())
        XCTAssertTrue(composed.spoken.hasSuffix(ProcessingSummary.evidenceCaveat), composed.spoken)
        XCTAssertTrue(ProcessingSummary.evidenceCaveat.contains("isn't a record"))
        XCTAssertTrue(ProcessingSummary.evidenceCaveat.contains("not a complete audit"))
    }

    func testEveryRowHasASpokenFormAndAShortValue() {
        let composed = ProcessingSummary.compose(facts: ProcessingFacts())
        XCTAssertEqual(composed.rows.map(\.kind), ProcessingRowKind.allCases)
        for row in composed.rows {
            XCTAssertFalse(row.spokenForm.isEmpty, "\(row.kind) has no spoken form")
            XCTAssertFalse(row.shortValue.isEmpty, "\(row.kind) has no short value")
            XCTAssertTrue(row.spokenForm.hasPrefix(row.kind.title),
                          "a row read out of context must still say what it is about")
        }
    }

    // MARK: - The voice route

    func testTheToolAnswersWithTheSameComposedSummary() async throws {
        let facts = ProcessingFacts(modelKind: .cloud, modelProviderName: "Anthropic (Claude)")
        let tool = ProcessingSummaryTool { facts }
        let spoken = try await tool.execute(args: [:])
        XCTAssertEqual(spoken, ProcessingSummary.compose(facts: facts).spoken)
    }

    /// Bare-query gated like `new_topic`: the phrase on its own is the question, and the same words
    /// inside a longer sentence are content.
    func testABareRoutingQuestionTakesTheDirectRouteAndALongerSentenceDoesNot() {
        let classifier = ConversationClassifier()

        let bare = classifier.classify("how are my requests processed")
        XCTAssertEqual(bare.directToolCall?.toolName, "processing_summary")

        let embedded = classifier.classify(
            "write a paragraph about how are my requests processed in a distributed system")
        XCTAssertNotEqual(embedded.directToolCall?.toolName, "processing_summary")
    }
}
