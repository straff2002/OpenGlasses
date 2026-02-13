import Foundation
import AVFoundation

/// Text-to-speech service using ElevenLabs for natural voice
/// Falls back to iOS AVSpeechSynthesizer if no API key or quota exhausted
@MainActor
class TextToSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?  // Separate ref so tone isn't killed by speech
    private var speechContinuation: CheckedContinuation<Void, Never>?

    /// Track if ElevenLabs quota is exhausted to skip future attempts
    private var elevenLabsDisabled: Bool = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(_ text: String) async {
        guard !text.isEmpty else { return }

        // Cancel any in-progress speech
        stopSpeaking()
        try? await Task.sleep(nanoseconds: 50_000_000)

        isSpeaking = true

        let elevenLabsKey = Config.elevenLabsAPIKey
        if !elevenLabsKey.isEmpty && !elevenLabsDisabled {
            do {
                try await speakWithElevenLabs(text: text, apiKey: elevenLabsKey)
            } catch {
                print("🔊 TTS: ElevenLabs failed (\(error)), falling back to iOS voice")
                await speakWithiOS(text: text)
            }
        } else {
            if elevenLabsDisabled {
                print("🔊 TTS: ElevenLabs disabled (quota exceeded), using iOS voice")
            }
            await speakWithiOS(text: text)
        }

        isSpeaking = false
        print("🔊 TTS: Finished speaking")
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speechContinuation?.resume()
        speechContinuation = nil
    }

    /// High tone — wake word heard, now listening
    func playAcknowledgmentTone() {
        playTone(frequency: 880, duration: 0.15)
    }

    /// Lower tone — finished listening, processing
    func playEndListeningTone() {
        playTone(frequency: 440, duration: 0.12)
    }

    /// Descending two-note tone — conversation ended, back to wake word
    func playDisconnectTone() {
        do {
            let toneData = try Self.generateDescendingToneData(sampleRate: 44100)
            let player = try AVAudioPlayer(data: toneData)
            self.tonePlayer = player
            player.volume = 0.7
            player.prepareToPlay()
            player.play()
        } catch {
            print("🔊 Disconnect tone failed: \(error)")
            // Single-note fallback
            playTone(frequency: 330, duration: 0.15)
        }
    }

    private func playTone(frequency: Double, duration: Double) {
        do {
            let toneData = try Self.generateToneData(frequency: frequency, duration: duration, sampleRate: 44100)
            let player = try AVAudioPlayer(data: toneData)
            self.tonePlayer = player
            player.volume = 0.7
            player.prepareToPlay()
            player.play()
        } catch {
            print("🔊 Tone failed: \(error)")
            AudioServicesPlaySystemSound(1054)
        }
    }

    /// Generate a short WAV tone in memory
    private static func generateToneData(frequency: Double, duration: Double, sampleRate: Double) throws -> Data {
        let numSamples = Int(sampleRate * duration)
        var samples = [Int16]()
        samples.reserveCapacity(numSamples)

        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            // Apply a quick fade-in/fade-out envelope to avoid clicks
            let envelope: Double
            let fadeLen = 0.01  // 10ms fade
            if t < fadeLen {
                envelope = t / fadeLen
            } else if t > duration - fadeLen {
                envelope = (duration - t) / fadeLen
            } else {
                envelope = 1.0
            }
            let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.8
            samples.append(Int16(sample * Double(Int16.max)))
        }

        // Build a minimal WAV file in memory
        var data = Data()
        let dataSize = UInt32(numSamples * 2)
        let fileSize = UInt32(36 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })  // sample rate
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })  // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })   // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        return data
    }

    /// Generate a descending two-note WAV tone (440Hz → 330Hz) for disconnect
    private static func generateDescendingToneData(sampleRate: Double) throws -> Data {
        let note1Freq = 440.0  // A4
        let note2Freq = 330.0  // E4 (a fourth down — pleasant interval)
        let noteDuration = 0.1
        let gapDuration = 0.04
        let fadeLen = 0.008

        let note1Samples = Int(sampleRate * noteDuration)
        let gapSamples = Int(sampleRate * gapDuration)
        let note2Samples = Int(sampleRate * noteDuration)
        let totalSamples = note1Samples + gapSamples + note2Samples

        var samples = [Int16]()
        samples.reserveCapacity(totalSamples)

        // Note 1: 440Hz
        for i in 0..<note1Samples {
            let t = Double(i) / sampleRate
            let envelope: Double
            if t < fadeLen { envelope = t / fadeLen }
            else if t > noteDuration - fadeLen { envelope = (noteDuration - t) / fadeLen }
            else { envelope = 1.0 }
            let sample = sin(2.0 * .pi * note1Freq * t) * envelope * 0.8
            samples.append(Int16(sample * Double(Int16.max)))
        }

        // Gap: silence
        for _ in 0..<gapSamples {
            samples.append(0)
        }

        // Note 2: 330Hz (lower)
        for i in 0..<note2Samples {
            let t = Double(i) / sampleRate
            let envelope: Double
            if t < fadeLen { envelope = t / fadeLen }
            else if t > noteDuration - fadeLen { envelope = (noteDuration - t) / fadeLen }
            else { envelope = 1.0 }
            let sample = sin(2.0 * .pi * note2Freq * t) * envelope * 0.8
            samples.append(Int16(sample * Double(Int16.max)))
        }

        // Build WAV
        var data = Data()
        let dataSize = UInt32(totalSamples * 2)
        let fileSize = UInt32(36 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        return data
    }

    // MARK: - ElevenLabs TTS

    private func speakWithElevenLabs(text: String, apiKey: String) async throws {
        let voiceId = Config.elevenLabsVoiceId
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)"

        guard let url = URL(string: urlString) else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.3
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("🔊 ElevenLabs: Requesting speech for \(text.count) chars...")
        let startTime = Date()

        let (data, response) = try await URLSession.shared.data(for: request)

        let elapsed = Date().timeIntervalSince(startTime)
        print("🔊 ElevenLabs: Received \(data.count) bytes in \(String(format: "%.1f", elapsed))s")

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let errorStr = String(data: data, encoding: .utf8) {
                print("🔊 ElevenLabs: Error \(statusCode): \(errorStr)")
                // Disable ElevenLabs if quota exceeded
                if errorStr.contains("quota_exceeded") {
                    print("🔊 ElevenLabs: Quota exceeded — disabling for this session")
                    elevenLabsDisabled = true
                }
            }
            throw TTSError.apiError(statusCode: statusCode)
        }

        // Play the MP3 audio
        try await playAudioData(data)
    }

    private func playAudioData(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.prepareToPlay()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speechContinuation = continuation
            player.delegate = self
            player.play()
            print("🔊 ElevenLabs: Playing audio (\(String(format: "%.1f", player.duration))s)")
        }
    }

    // MARK: - iOS Fallback TTS

    private func speakWithiOS(text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        // Try to use a premium voice if available
        if let premiumVoice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe") {
            utterance.voice = premiumVoice
        } else if let enhancedVoice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Zoe") {
            utterance.voice = enhancedVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speechContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate (iOS fallback)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            print("🔊 iOS TTS: didFinish")
            self.speechContinuation?.resume()
            self.speechContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            print("🔊 iOS TTS: didCancel")
            self.speechContinuation?.resume()
            self.speechContinuation = nil
        }
    }
}

// MARK: - AVAudioPlayerDelegate (ElevenLabs)

extension TextToSpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            print("🔊 ElevenLabs: Playback finished (success=\(flag))")
            self.audioPlayer = nil
            self.speechContinuation?.resume()
            self.speechContinuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("🔊 ElevenLabs: Decode error: \(error?.localizedDescription ?? "unknown")")
            self.audioPlayer = nil
            self.speechContinuation?.resume()
            self.speechContinuation = nil
        }
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int)
    case audioPlaybackFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid ElevenLabs URL"
        case .apiError(let code): return "ElevenLabs API error: \(code)"
        case .audioPlaybackFailed: return "Audio playback failed"
        }
    }
}
