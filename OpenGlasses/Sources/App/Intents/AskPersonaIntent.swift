import AppIntents

/// Persona-targeted conversational Siri intent:
/// *"Hey Siri, ask Claude on OpenGlasses what's on my calendar."*
///
/// Carries the persona as an `AppEntity` parameter (allowed inside an AppShortcut
/// phrase, so the persona name can ride in one breath) and the question as a
/// two-step `requestValueDialog` parameter. Runs the query under the chosen
/// persona's model + prompt preset, has Siri speak the answer, then restores the
/// previously-active model so a one-off Siri ask never permanently switches the
/// user's setup.
///
/// The persona is **optional**: omit it ("Ask OpenGlasses a question") and it
/// falls back to the active persona, else the first enabled one — so this single
/// intent serves both the generic and the persona-targeted ask.
// AudioRecordingIntent: background mic-start rights (see AskOpenGlassesIntent).
// Not an `AudioRecordingIntent`: this intent never opens the microphone (Siri resolves the
// question), and that conformance makes iOS abort the app if the audio session happens to be
// active at return without a Live Activity — see `AppState.startAskWithoutWakeWord`.
struct AskPersonaIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask a Persona"
    static var description = IntentDescription(
        "Ask a specific Avenkin persona by voice and hear the answer"
    )

    static var openAppWhenRun: Bool { Config.siriAskOpensApp }
    static var isDiscoverable: Bool { true }

    @Parameter(title: "Persona")
    var persona: PersonaEntity?

    @Parameter(
        title: "Question",
        description: "What you want to ask",
        requestValueDialog: "What would you like to ask?"
    )
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        // Step 1 — await the connection signal (shared with AskQuestionIntent).
        let appState = try await IntentSupport.awaitConnectedAppState()

        // Don't ride a stale `lastResponse` if a voice turn is already in flight.
        guard !appState.isProcessing else {
            throw IntentError.busy
        }

        // Step 2 — the question is resolved two-step by Siri before we get here.
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.emptyQuestion
        }

        let resolved = resolvePersona(appState: appState)

        // Conversational follow-up: continue a recent Siri thread, else start fresh.
        if Config.conversationPersistenceEnabled {
            appState.conversationStore.continueRecentOrStartThread(
                mode: appState.currentMode.rawValue,
                within: Self.followUpWindow
            )
        }

        // Run under the persona (model + preset), restoring the prior setup after.
        if let resolved {
            await appState.askUnderPersona(resolved, question: trimmed)
        } else {
            await appState.sendTextMessage(trimmed, speakResponse: false)
        }

        let answer = appState.lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw IntentError.noResponse
        }

        let snippet = AnswerSnippetView(personaName: resolved?.name, answer: answer)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer), view: snippet)
    }

    /// Consecutive Siri asks within this window continue the same conversation thread.
    private static let followUpWindow: TimeInterval = 5 * 60

    /// Resolve which persona to run under: the explicitly named one (if still
    /// enabled), else the currently-active persona, else the first enabled persona.
    @MainActor
    private func resolvePersona(appState: AppState) -> Persona? {
        if let persona, let match = Config.enabledPersonas.first(where: { $0.id == persona.id }) {
            return match
        }
        if let active = appState.activePersona {
            return active
        }
        return Config.enabledPersonas.first
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
