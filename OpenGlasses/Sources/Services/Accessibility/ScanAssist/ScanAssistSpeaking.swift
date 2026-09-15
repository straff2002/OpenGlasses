import Foundation

/// The only way Scan Assist makes a sound.
///
/// Three methods, all of them already `TextToSpeechService`'s: a reminder is spoken by the same
/// engine chain, over the same audio lease, on the same route as everything else the app says
/// (docs/plans/FB-scan-assist.md P1 — "Scan cues must not be VoiceOver-only announcements or a new
/// private audio player"). There is no `AVAudioPlayer` anywhere in this feature, and there is no
/// `UIAccessibility.post` either: a cue a wearer only hears when VoiceOver happens to be on is not
/// a cue.
///
/// It exists as a protocol so tests can record what was spoken, toned and cancelled without an
/// audio session — not so a second implementation can start playing audio of its own.
@MainActor
protocol ScanAssistSpeaking: AnyObject {
    /// Speak one reminder. Named apart from `TextToSpeechService.speak(_:urgency:mirrorToHUD:)`
    /// because a requirement cannot be witnessed by a method that only matches through default
    /// arguments.
    func speakCue(_ text: String) async
    /// The `.sound` cue style. A short tone, on the shared player, at the current route — not
    /// steered to one ear and not a claim of spatial audio.
    func playTone(frequency: Double, duration: Double)
    /// Drop anything queued or in flight. Called on stop and on expiry so a session that is over
    /// cannot still be heard finishing a sentence.
    func stopSpeaking()
}

extension TextToSpeechService: ScanAssistSpeaking {
    func speakCue(_ text: String) async {
        // `.low` deliberately: a reminder the wearer configured for themselves is not urgent, and
        // `.high` would prefix it with "Important:" every thirty seconds for five minutes.
        await speak(text, urgency: .low)
    }
}
