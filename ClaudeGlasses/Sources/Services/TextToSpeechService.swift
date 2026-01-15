import Foundation
import AVFoundation

/// Text-to-speech service for speaking Claude's responses
/// Routes audio to Bluetooth devices (glasses) when connected
@MainActor
class TextToSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: (error)")
        }
    }

    func speak(_ text: String) async {
        guard !text.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)

        // Wait for speech to complete
        await withCheckedContinuation { continuation in
            Task {
                while synthesizer.isSpeaking {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                continuation.resume()
            }
        }

        isSpeaking = false
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func playAcknowledgmentTone() {
        // Play a short tone to acknowledge wake word detection
        let systemSoundID: SystemSoundID = 1057 // Tink sound
        AudioServicesPlaySystemSound(systemSoundID)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
