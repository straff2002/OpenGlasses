import AppIntents

/// Conversational Siri intent: speak a question and route it through the full
/// LLM/persona pipeline, then have Siri read the answer back.
///
/// This is the "Hey Siri" entry point that mirrors how third-party projects wake
/// the glasses workflow from Siri (e.g. a Siri Shortcut wrapping an App Intent).
/// Unlike `AskOpenGlassesIntent` — which only starts the microphone — this intent
/// answers in-line and has Siri speak the result.
///
/// **Two-step conversation.** A free-form `String` can't be carried inside an
/// `AppShortcut` phrase (the AppIntents metadata processor only allows `AppEntity`
/// / `AppEnum`-typed parameters there), so the flow is deliberately two-step:
///
///   1. **"Hey Siri, ask OpenGlasses a question"** → Siri resolves the missing
///      `question` parameter via `requestValueDialog` ("What would you like to
///      ask?") and awaits the spoken reply.
///   2. The reply is routed through `sendTextMessage` and Siri speaks the answer.
///
/// Because the intent runs in the background by default (`openAppWhenRun == false`
/// unless the user flips `Config.siriAskOpensApp`), Siri can invoke `perform()`
/// before the app scene is fully resident — increasingly so under the more
/// background-driven, conversational Siri in iOS 27. So step 1 first *awaits a
/// connection signal*: it waits briefly for `AppStateProvider.shared` to come up
/// rather than failing the instant it's nil. The answer is returned as a spoken
/// `dialog`, so Siri — not the in-app TTS — reads it aloud (`speakResponse: false`).
// AudioRecordingIntent: background mic-start rights (see AskOpenGlassesIntent).
// Not an `AudioRecordingIntent`: this intent never opens the microphone (Siri resolves the
// question), and that conformance makes iOS abort the app if the audio session happens to be
// active at return without a Live Activity — see `AppState.startAskWithoutWakeWord`.
struct AskQuestionIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Avenkin a Question"
    static var description = IntentDescription(
        "Ask Avenkin anything by voice and hear the answer, without the wake word"
    )

    // By default, run in the background so Siri can speak the answer without forcing
    // the app to the foreground (OpenGlasses normally stays running for wake words,
    // so `AppStateProvider.shared` is populated). Users who'd rather guarantee it
    // launches can flip "Open app for Siri questions" in Settings.
    static var openAppWhenRun: Bool { Config.siriAskOpensApp }
    static var isDiscoverable: Bool { true }

    @Parameter(
        title: "Question",
        description: "What you want to ask Avenkin",
        requestValueDialog: "What would you like to ask?"
    )
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        // Step 1 — await the connection signal (shared with the persona intent).
        // The app may not be wired up the instant Siri calls us (background
        // invocation, or a fresh launch when `siriAskOpensApp` is on).
        let appState = try await IntentSupport.awaitConnectedAppState()

        // Don't ride on a stale `lastResponse`: if a wake-word/voice turn is already
        // in flight, `sendTextMessage` would no-op and we'd speak the previous answer.
        guard !appState.isProcessing else {
            throw IntentError.busy
        }

        // Step 2 — the question is resolved two-step by Siri (requestValueDialog)
        // before we get here, so `question` is populated; guard the empty edge case.
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.emptyQuestion
        }

        // Route through the same pipeline the wake word uses, but let Siri speak
        // the result instead of the in-app TTS engine.
        await appState.sendTextMessage(trimmed, speakResponse: false)

        let answer = appState.lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw IntentError.noResponse
        }

        let snippet = AnswerSnippetView(personaName: appState.activePersona?.name, answer: answer)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer), view: snippet)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case busy
        case emptyQuestion
        case noResponse

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .busy:
                return "Avenkin is still working on something. Try again in a moment."
            case .emptyQuestion:
                return "I didn't catch a question."
            case .noResponse:
                return "Sorry, I couldn't get an answer."
            }
        }
    }
}
