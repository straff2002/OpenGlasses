import AVFoundation
import Foundation

/// Where the app says it is an AI (Plan HP P2 item 10). What is said, and how often, is decided by
/// `AIDisclosureLedger` (once per launch per surface, the first-ever introduction, the wearer's cue
/// switch) and `TranslationDisclosureLanguage` (the other person's language, and whether they can
/// hear it); this file only speaks it at the right moments.
///
/// Every line goes through the app's own voice with the HUD mirror on, so a wearer with a display
/// sees it as well as hears it — except the line for the other person, which is not the wearer's
/// to read.
extension AppState {

    /// Direct mode before the first answer of the launch, and both live modes as a session
    /// connects: "Connecting to Avenkin AI." — or, on the install's first conversation ever, the
    /// longer introduction, whatever the switch says.
    func speakConversationCueIfDue() async {
        guard let line = AIDisclosureLedger.shared.consume(
            .conversation, cueEnabled: Config.aiConnectionCueEnabled) else { return }
        await speechService.speak(line)
    }

    /// A live translation or a translated-caption session has started.
    ///
    /// The wearer hears "Starting Avenkin AI translation." once per launch, under the same switch
    /// as the conversation cue. When the translation is spoken (`spokenAloud`) and will come out of
    /// the phone's loudspeaker, the other person is also told, once per launch and in the language
    /// they are being translated into, that this is a live AI translation. That one is not the
    /// wearer's to switch off.
    func announceTranslationStarted(target: String, spokenAloud: Bool) async {
        if let line = AIDisclosureLedger.shared.consume(
            .translation, cueEnabled: Config.aiConnectionCueEnabled) {
            await speechService.speak(line)
        }
        guard spokenAloud else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        guard TranslationDisclosureLanguage.playsFromPhoneSpeaker(outputs: outputs,
                                                                  glassesOnlyAudio: Config.glassesOnlyAudio),
              AIDisclosureLedger.shared.consume(.translationForListener) != nil else { return }
        await speechService.speak(TranslationDisclosureLanguage.listenerLine(forTarget: target),
                                  mirrorToHUD: false)
    }

    /// Point every surface that can start a conversation or a translation at the lines above.
    /// Called once from setup.
    func wireAIDisclosures() {
        geminiLiveSession.onWillConnect = { [weak self] in
            await self?.speakConversationCueIfDue()
        }
        openAIRealtimeSession.onWillConnect = { [weak self] in
            await self?.speakConversationCueIfDue()
        }
        liveTranslation.onSessionStarted = { [weak self] target in
            Task { @MainActor in await self?.announceTranslationStarted(target: target, spokenAloud: true) }
        }
        ambientCaptions.onTranslationSessionStarted = { [weak self] in
            // Captions are read, not spoken: the wearer is told, and the other person reads the
            // "AI translation" label on their half of the split screen.
            Task { @MainActor in
                await self?.announceTranslationStarted(target: Config.translationLanguageB, spokenAloud: false)
            }
        }
        // Live translation translates on the phone, through Apple's Translation framework — the
        // engine the translated captions' on-device tier already uses. Nothing leaves the device,
        // and a sentence that cannot be translated is not spoken (Plan HP P2 item 13).
        let engine = translationEngine
        liveTranslation.translateText = { [weak engine] text, source, target in
            guard let engine else { throw TranslationProviderError.notConfigured }
            return try await engine.translate(text, from: source, to: target)
        }
    }
}
