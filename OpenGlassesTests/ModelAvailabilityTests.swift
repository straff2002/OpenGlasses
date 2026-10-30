import XCTest
@testable import OpenGlasses

/// Plan KA P2 — whether a model can be chosen for a job beyond its kind: its provider's shutdown
/// day (OpenAI's `shutdown_date`, read from the real list a key returned on 2026-10-30) and whether
/// the app has a connection that reaches it. The live results (which ids OpenAI's speech,
/// transcription and realtime endpoints accept) were checked by the owner with a key the same day;
/// no key is needed here. Every date is injected.
final class ModelAvailabilityTests: XCTestCase {

    private func day(_ text: String) -> Date { ModelShutdown(text)!.date }
    private lazy var today = day("2026-10-30")

    private func status(_ provider: LLMProvider, _ id: String, _ role: ModelRole,
                        on date: Date? = nil) -> ModelChoiceStatus {
        ModelChoiceStatus.of(provider: provider, id: id, kind: ModelKindClassifier.kind(provider: provider, id: id),
                             for: role, today: date ?? today)
    }

    private func canUse(_ provider: LLMProvider, _ id: String, _ role: ModelRole) -> Bool {
        ModelTransport.canUse(provider: provider, id: id, for: role)
    }

    // MARK: - Shutdown days

    func testAShutdownDayIsReadFromTheListsOwnField() {
        XCTAssertEqual(ModelShutdown("2027-01-06"), ModelShutdown(year: 2027, month: 1, day: 6))
        XCTAssertEqual(ModelShutdown("2027-01-06T00:00:00Z"), ModelShutdown(year: 2027, month: 1, day: 6))
        for bad in ["", "2027-1-6", "soon", "2027-13-01", "20270106"] {
            XCTAssertNil(ModelShutdown(bad), bad)
        }
        XCTAssertEqual(ModelListMetadata(row: ["id": "tts-1", "shutdown_date": "2027-01-06"]).shutdown,
                       ModelShutdown(year: 2027, month: 1, day: 6))
        XCTAssertNil(ModelListMetadata(row: ["id": "gpt-5.4-mini", "shutdown_date": NSNull()]).shutdown)
        XCTAssertNil(ModelListMetadata(row: ["id": "gpt-5.4-mini"]).shutdown)
    }

    func testAShutdownDayStartsAtMidnightUTC() {
        let shutdown = ModelShutdown(year: 2027, month: 1, day: 6)
        XCTAssertFalse(shutdown.hasPassed(on: shutdown.date.addingTimeInterval(-1)))
        XCTAssertTrue(shutdown.hasPassed(on: shutdown.date))
        XCTAssertTrue(shutdown.isWithin(days: 90, of: day("2026-10-30")))
        XCTAssertFalse(shutdown.isWithin(days: 90, of: day("2026-09-01")), "127 days out")
        XCTAssertFalse(shutdown.isWithin(days: 90, of: day("2027-01-07")), "already gone")
        XCTAssertTrue(shutdown.displayDate.contains("2027"))
    }

    /// The real list's dates reach the models a picker gets.
    func testTheOpenAIListCarriesItsShutdownDates() throws {
        let models = try OpenAIModelListFixture.models()
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.shutdown) })
        XCTAssertEqual(byID["gpt-4o"] ?? nil, ModelShutdown("2027-01-14"))
        XCTAssertEqual(byID["gpt-4o-mini-tts"] ?? nil, ModelShutdown("2027-01-06"))
        XCTAssertEqual(byID["whisper-1"] ?? nil, ModelShutdown("2027-02-26"))
        XCTAssertEqual(byID["gpt-realtime-mini"] ?? nil, ModelShutdown("2027-01-20"))
        XCTAssertEqual(byID["gpt-image-1"] ?? nil, ModelShutdown("2026-10-23"))
        for undated in ["gpt-5.4-mini", "gpt-5.4", "gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-transcribe",
                        "gpt-live-transcribe", "gpt-live-1"] {
            XCTAssertNil(byID[undated] ?? nil, undated)
        }
    }

    /// The table a saved model's warning reads holds exactly the dated ids of the list it was
    /// taken from, so the two can't drift apart unnoticed.
    func testThePublishedDatesMatchTheList() throws {
        for row in try OpenAIModelListFixture.rows() {
            let id = try XCTUnwrap(row["id"] as? String)
            let listed = (row["shutdown_date"] as? String).flatMap(ModelShutdown.init)
            XCTAssertEqual(ModelShutdownCalendar.openAIDates[id], listed, id)
        }
        XCTAssertEqual(ModelShutdownCalendar.openAIDates.count, 88)
    }

    func testOnlyOpenAIsDatesAreKnownAndTheListWins() {
        XCTAssertNotNil(ModelShutdownCalendar.shutdown(provider: .openai, id: " GPT-4o "))
        XCTAssertNil(ModelShutdownCalendar.shutdown(provider: .custom, id: "gpt-4o"),
                     "a custom server's names are its own")
        XCTAssertNil(ModelShutdownCalendar.shutdown(provider: .openrouter, id: "gpt-4o"))
        let listed = ModelShutdown(year: 2030, month: 1, day: 1)
        XCTAssertEqual(ModelShutdownCalendar.shutdown(provider: .openai, id: "gpt-4o", listed: listed), listed)
        XCTAssertEqual(ModelShutdownCalendar.shutdown(provider: .openai, id: "gpt-4o-realtime-preview-2024-12-17"),
                       ModelShutdown("2026-05-07"), "a removed realtime preview is dated by the retirement table")
    }

    // MARK: - Choosing a dated model

    func testARetiredModelCantBeTheAssistant() {
        XCTAssertEqual(status(.openai, "o4-mini", .assistant), .retired(ModelShutdown("2026-10-23")!))
        XCTAssertEqual(status(.openai, "o4-mini", .assistant).unavailableLabel, "Retired")
        XCTAssertFalse(status(.openai, "gpt-3.5-turbo", .vision).isChoosable)
    }

    func testAModelRetiringWithin90DaysStaysChoosableAndSaysWhen() {
        let gpt4o = status(.openai, "gpt-4o", .assistant)
        XCTAssertTrue(gpt4o.isChoosable)
        XCTAssertEqual(gpt4o, .choosable(retiring: ModelShutdown("2027-01-14")))
        XCTAssertTrue(gpt4o.note?.hasPrefix("Retires") ?? false)
        XCTAssertEqual(status(.openai, "gpt-5.1", .assistant), .choosable(retiring: nil), "2027-04-01 is 153 days out")
        XCTAssertNil(status(.openai, "gpt-5.4-mini", .assistant).note)
    }

    /// From the real list on its own day: the assistant's picker offers the current models,
    /// notes the retiring ones, and dims the retired ones and every non-chat model.
    func testTheChatPickerSplitsTheRealList() throws {
        let models = try OpenAIModelListFixture.models()
        let choosable = Set(models.filter { $0.assistantStatus(provider: .openai, today: today).isChoosable }.map(\.id))
        for id in ["gpt-5.4-mini", "gpt-6-luna", "gpt-4o", "gpt-5", "gpt-audio-1.5"] {
            XCTAssertTrue(choosable.contains(id), id)
        }
        for id in ["o4-mini", "gpt-3.5-turbo", "babbage-002", "gpt-5-codex", "tts-1", "gpt-realtime-2.1", "sora-2"] {
            XCTAssertFalse(choosable.contains(id), id)
        }
    }

    func testTheChatPickersDimmedLabelSaysWhyAndWhetherTheAppCanReachIt() {
        func label(_ provider: LLMProvider, _ id: String, kind: ModelKind? = nil) -> String {
            ModelChoiceStatus.assistantSectionLabel(
                provider: provider, id: id, kind: kind ?? ModelKindClassifier.kind(provider: provider, id: id),
                today: today)
        }
        XCTAssertEqual(label(.openai, "gpt-realtime-2.1"), ModelKind.realtime.label)
        XCTAssertEqual(label(.openai, "gpt-live-1"),
                       "\(ModelKind.realtime.label) · Needs a connection the app doesn't have yet")
        XCTAssertEqual(label(.openai, "gpt-live-transcribe"),
                       "\(ModelKind.transcription.label) · Needs a connection the app doesn't have yet")
        XCTAssertEqual(label(.mistral, "voxtral-mini-tts-3-0"),
                       "\(ModelKind.speech.label) · Needs a connection the app doesn't have yet")
        XCTAssertEqual(label(.openai, "sora-2"), "\(ModelKind.video.label) · Retired")
        XCTAssertEqual(label(.openai, "o1"), "Retired")
        XCTAssertEqual(label(.openai, "gpt-image-2"), ModelKind.image.label, "no images job yet, so no connection claim")
    }

    func testAPickerNeverStartsOnARetiredModelAndPrefersAnUndatedOne() {
        let retired = ModelFetcher.RemoteModel(id: "o1", name: "o1", shutdown: ModelShutdown("2026-10-23"))
        let dated = ModelFetcher.RemoteModel(id: "gpt-4o", name: "gpt-4o", shutdown: ModelShutdown("2027-01-14"))
        let undated = ModelFetcher.RemoteModel(id: "gpt-5.4", name: "gpt-5.4")
        let models = [retired, dated, undated]
        XCTAssertEqual(ModelFetcher.initialChoice(in: models, preferring: ["absent"], today: today), "gpt-5.4")
        XCTAssertEqual(ModelFetcher.initialChoice(in: models, preferring: ["o1"], today: today), "gpt-5.4")
        XCTAssertEqual(ModelFetcher.initialChoice(in: models, preferring: ["gpt-4o"], today: today), "gpt-4o",
                       "a retiring model the wearer's default names is still allowed")
        XCTAssertNil(ModelFetcher.initialChoice(in: [retired], preferring: [], today: today))
    }

    func testTheSavedModelWarningSaysRetiredOrRetiring() {
        let retired = ModelShutdownCalendar.savedModelWarning(provider: .openai, id: "o3-mini", today: today)
        XCTAssertTrue(retired?.hasPrefix("Retired on") ?? false)
        let retiring = ModelShutdownCalendar.savedModelWarning(provider: .openai, id: "gpt-4o", today: today)
        XCTAssertTrue(retiring?.hasPrefix("Retires") ?? false)
        XCTAssertNil(ModelShutdownCalendar.savedModelWarning(provider: .openai, id: "gpt-5.4-mini", today: today))
        XCTAssertNil(ModelShutdownCalendar.savedModelWarning(provider: .openai, id: "gpt-5.1", today: today))
        XCTAssertNil(ModelShutdownCalendar.savedModelWarning(provider: .anthropic, id: "claude-sonnet-5", today: today))
    }

    /// Settings shows the shutdown warning beside the existing kind warning.
    func testASavedModelRowCarriesBothWarnings() {
        let speech = ModelConfig(id: "s", name: "Speech", provider: LLMProvider.openai.rawValue, apiKey: "k",
                                 model: "tts-1", baseURL: "")
        let warnings = AIPersonalitySettingsScreen.savedModelWarnings(speech, today: today)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(warnings.first, ModelKind.speech.savedModelWarning)
        XCTAssertTrue(warnings.last?.hasPrefix("Retires") ?? false)
        let current = ModelConfig(id: "c", name: "Current", provider: LLMProvider.openai.rawValue, apiKey: "k",
                                  model: "gpt-5.4-mini", baseURL: "")
        XCTAssertEqual(AIPersonalitySettingsScreen.savedModelWarnings(current, today: today), [])
    }

    // MARK: - What the app can reach (owner's key, 2026-10-30)

    /// The realtime socket completed a full turn with the 2.1 models and refused `gpt-live-1`
    /// (`invalid_model`); `gpt-realtime-translate` is for the translations endpoint only.
    func testOpenAILiveTakesOnlyTheRealtimeSocketsModels() {
        for id in ["gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-realtime-2", "gpt-realtime-1.5",
                   "gpt-realtime", "gpt-realtime-mini"] {
            XCTAssertTrue(canUse(.openai, id, .live), id)
        }
        for id in ["gpt-live-1", "gpt-realtime-translate", "gpt-realtime-whisper", "gpt-audio-1.5", "gpt-5.4-mini"] {
            XCTAssertFalse(canUse(.openai, id, .live), id)
        }
    }

    /// The upload endpoint took `gpt-transcribe` and `gpt-4o-transcribe`; the streaming-session
    /// models answered "Invalid URL".
    func testOpenAIDictationTakesOnlyUploadModels() {
        for id in ["gpt-transcribe", "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            XCTAssertTrue(canUse(.openai, id, .dictation), id)
        }
        for id in ["gpt-live-transcribe", "gpt-realtime-whisper", "gpt-4o-transcribe-diarize"] {
            XCTAssertFalse(canUse(.openai, id, .dictation), id)
        }
    }

    /// The speech endpoint took `gpt-4o-mini-tts`; `gpt-realtime-2.1-mini` and `gpt-audio-1.5`
    /// answered 404.
    func testOpenAIVoiceTakesOnlySpeechEndpointModels() {
        for id in ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"] {
            XCTAssertTrue(canUse(.openai, id, .voice), id)
        }
        for id in ["gpt-realtime-2.1-mini", "gpt-audio-1.5"] {
            XCTAssertFalse(canUse(.openai, id, .voice), id)
        }
    }

    func testStreamingOnlyAndUnconnectedModelsAreOutOfReach() {
        XCTAssertFalse(canUse(.mistral, "voxtral-mini-tts-realtime-3-0", .voice))
        XCTAssertFalse(canUse(.mistral, "voxtral-mini-tts-3-0", .voice), "no Mistral voice connection yet")
        XCTAssertFalse(canUse(.gemini, "gemini-3.5-transcribe-live", .dictation))
        XCTAssertFalse(canUse(.gemini, "gemini-3.5-transcribe", .dictation), "no Gemini dictation connection yet")
        XCTAssertFalse(canUse(.gemini, "gemini-3.5-live-translate-preview", .live))
        XCTAssertFalse(canUse(.xai, "grok-voice-latest", .live), "xAI's voice agent has no connection in the app")
        XCTAssertTrue(canUse(.gemini, "gemini-3.8-flash-tts", .voice))
        XCTAssertTrue(canUse(.gemini, "gemini-3.8-live", .live))
        XCTAssertFalse(canUse(.openai, "gpt-image-2", .images), "no image tool yet")
    }

    func testTheNeedsConnectionStatusIsDimmedAndLabelled() {
        let live1 = status(.openai, "gpt-live-1", .live)
        XCTAssertEqual(live1, .needsConnection)
        XCTAssertFalse(live1.isChoosable)
        XCTAssertEqual(live1.unavailableLabel, "Needs a connection the app doesn't have yet")
        XCTAssertEqual(status(.openai, "gpt-4o-mini-tts", .live), .wrongKind(.speech))
        XCTAssertEqual(status(.openai, "gpt-realtime-mini", .live), .choosable(retiring: ModelShutdown("2027-01-20")))
        XCTAssertEqual(status(.openai, "gpt-realtime-mini", .live, on: day("2027-01-20")),
                       .retired(ModelShutdown("2027-01-20")!))
    }

    // MARK: - Defaults

    /// No default names a model with a shutdown day, and each one the app can reach. The one
    /// exception is OpenAI's voice: every model its speech endpoint takes retires 2027-01-06 and
    /// none replaces it there, so Plan KB decides what follows.
    func testNoDefaultHasAShutdownDayAndEachIsReachable() {
        for provider in LLMProvider.allCases {
            for role in ModelRole.shown {
                guard let id = ModelRoleDefaults.model(for: role, provider: provider) else { continue }
                if provider == .openai && role == .voice {
                    XCTAssertEqual(ModelShutdownCalendar.shutdown(provider: provider, id: id), ModelShutdown("2027-01-06"))
                    continue
                }
                XCTAssertNil(ModelShutdownCalendar.shutdown(provider: provider, id: id), "\(provider) \(role) \(id)")
                if role != .assistant && role != .vision {
                    XCTAssertTrue(canUse(provider, id, role), "\(provider) \(role) \(id)")
                }
            }
            if let suggested = ModelRoleDefaults.model(for: .live, provider: provider, fromSuggestion: true) {
                XCTAssertNil(ModelShutdownCalendar.shutdown(provider: provider, id: suggested))
                XCTAssertTrue(canUse(provider, suggested, .live), "\(provider) \(suggested)")
            }
        }
    }

    /// The OpenAI defaults are in the real list, undated.
    func testTheOpenAIDefaultsAreInTheRealListWithNoShutdownDay() throws {
        let byID = Dictionary(uniqueKeysWithValues: try OpenAIModelListFixture.models().map { ($0.id, $0) })
        for id in [LLMProvider.openai.defaultModel, ModelRoleDefaults.model(for: .vision, provider: .openai),
                   ModelRoleDefaults.model(for: .live, provider: .openai),
                   ModelRoleDefaults.model(for: .live, provider: .openai, fromSuggestion: true),
                   ModelRoleDefaults.model(for: .dictation, provider: .openai)].compactMap({ $0 }) {
            let listed = try XCTUnwrap(byID[id], id)
            XCTAssertNil(listed.shutdown, id)
        }
    }

    /// The assistant defaults moved off ids their providers no longer list (docs, 2026-10-30).
    func testTheAssistantDefaultsAreCurrent() {
        XCTAssertEqual(LLMProvider.anthropic.defaultModel, "claude-sonnet-5-5")
        XCTAssertEqual(LLMProvider.openai.defaultModel, "gpt-5.4-mini")
        XCTAssertEqual(LLMProvider.zai.defaultModel, "glm-5.3")
        XCTAssertEqual(LLMProvider.minimax.defaultModel, "MiniMax-M3")
        XCTAssertEqual(Config.claudeModel, LLMProvider.anthropic.defaultModel)
        XCTAssertEqual(ModelFetcher.miniMaxProbeModels.first?.0, LLMProvider.minimax.defaultModel)
    }
}
