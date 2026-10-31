import Foundation

/// Starting the spoken interpreter from a request, and putting back what it took over from.
///
/// The session itself is `RealtimeSessionManager`'s. What belongs here is that the request usually
/// comes from somewhere else: Direct mode, or a Live session with the wearer's whole context in it.
/// So the turn that asked gets to finish, the interpreter runs as a Gemini Live session of its own,
/// and the wearer ends up back in the mode they asked from.
extension AppState {

    /// The longest a request waits for the turn it was made in to finish speaking.
    private static let turnWaitLimit: TimeInterval = 20

    /// `live_translate` with `mode: "conversation"`. Returns what the wearer is told, and starts the
    /// session once that has been said.
    func startInterpreter(otherLanguage: String?) -> String {
        guard let pair = InterpreterPair.resolving(requested: otherLanguage,
                                                   wearer: Config.translationLanguageA,
                                                   fallbackOther: Config.translationLanguageB) else {
            let names = TranslationLanguages.curated.map(\.name).joined(separator: ", ")
            return "The interpreter can't do that language. It can do: \(names)."
        }
        if let refusal = InterpreterGate.refusal(
            Config.interpreterGateInputs(pair: pair, usesGeminiLive: true)) {
            return refusal.spokenReason
        }
        Task { @MainActor [weak self] in await self?.runInterpreter(pair) }
        return "Starting the interpreter between \(TranslationPromptBuilder.languageName(pair.wearer)) and "
            + "\(TranslationPromptBuilder.languageName(pair.other)). Hold the phone between you. "
            + "Say 'stop translating' when you're done."
    }

    private func runInterpreter(_ pair: InterpreterPair) async {
        await waitForTheTurnToFinish()
        if liveTranslation.isActive { liveTranslation.stop() }
        interpreterReturnMode = currentMode == .geminiLive ? nil : currentMode
        geminiLiveSession.interpreterRequest = pair
        _ = await requestLiveSession(.geminiLive, source: .voice, restartIfActive: true)
        // A refused start never became a session, so nothing else will bring the wearer back.
        if !geminiLiveSession.isActive {
            geminiLiveSession.interpreterRequest = nil
            await returnFromInterpreter()
        }
    }

    private func waitForTheTurnToFinish() async {
        let deadline = Date().addingTimeInterval(Self.turnWaitLimit)
        repeat {
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
            && (isProcessing || speechService.isSpeaking || geminiLiveSession.isModelSpeaking)
    }

    /// The session ended, however it ended. A wearer who has since moved on to another mode stays
    /// there.
    func returnFromInterpreter() async {
        guard let mode = interpreterReturnMode else { return }
        interpreterReturnMode = nil
        guard currentMode == .geminiLive else { return }
        isLeavingInterpreter = true
        await performModeSwitch(to: mode)
        isLeavingInterpreter = false
    }
}
