import Foundation
import AVFoundation

/// Text-to-speech service using ElevenLabs for natural voice
/// Falls back to iOS AVSpeechSynthesizer if no API key or quota exhausted
@MainActor
class TextToSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking: Bool = false

    /// When true, TTS only speaks when glasses are connected (privacy mode).
    /// Set to false to allow phone speaker output without glasses.
    var requireGlassesForSpeech: Bool = true

    /// Checked before speaking — set by AppState when glasses connect/disconnect.
    var glassesConnected: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?  // Separate ref so tone isn't killed by speech
    private var speechContinuation: CheckedContinuation<Void, Never>?

    /// Tracks the current speech task so concurrent calls can be cancelled
    private var currentSpeechTask: Task<Void, Never>?

    /// Generation counter — incremented on each speak() call. Delegate callbacks
    /// check this to ignore stale completions from a previous speech session.
    private var speechGeneration: Int = 0

    /// When ElevenLabs returns quota_exceeded, cache the failure so we skip
    /// further ElevenLabs calls and go straight to iOS TTS for the session.
    private var elevenLabsQuotaExhausted = false

    /// A voice available on the user's ElevenLabs account (from GET /v1/voices).
    struct ElevenLabsVoice: Identifiable, Hashable, Codable {
        let voiceId: String
        let name: String
        let category: String?

        var id: String { voiceId }

        enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
            case name
            case category
        }
    }

    private struct ElevenLabsVoicesResponse: Codable {
        let voices: [ElevenLabsVoice]
    }

    /// Fetch the voices the given API key can actually use. Public-library voices are
    /// often rejected on free accounts, so the picker loads the account's own voices.
    static func fetchElevenLabsVoices(apiKey: String) async throws -> [ElevenLabsVoice] {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            throw TTSError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let body = String(data: data, encoding: .utf8) {
                print("🔊 ElevenLabs voices error \(code): \(body)")
            }
            throw TTSError.apiError(statusCode: code)
        }
        return try JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data).voices
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Audio pause hold
    //
    // Music/podcasts should fully pause while the agent speaks and resume after. The
    // actual session swap lives in WakeWordService.pauseOtherAudio/resumeOtherAudio and
    // is reference-counted there, so this pairs cleanly with the conversation flow's
    // own pause holds — Music/Podcasts stay paused for the whole interaction even when
    // multiple TTS utterances and the mic-active period overlap.

    /// Set by AppState — TTS service holds a weak reference so it can pause/resume
    /// the same shared session the wake-word listener uses.
    weak var wakeWordService: WakeWordService?
    private var didHoldPause = false

    /// Set by AppState — spoken text is mirrored to the in-lens HUD when the Glasses
    /// Display feature is on. The service no-ops on glasses without a display.
    weak var glassesDisplay: GlassesDisplayService?

    /// Set by AppState — lets the engine selector know whether we're online, so a configured
    /// ElevenLabs key isn't preferred while offline. Nil (unwired) is treated as online, preserving
    /// the historical "just try ElevenLabs and fall back on network error" behaviour.
    weak var reachability: Reachability?

    /// On-device neural voice (Additional Capabilities #1). A no-op until the model is downloaded
    /// *and* the `KOKORO_ENABLED` binary is compiled in, so in the shipped build `isReady` is false
    /// and the selector falls through to ElevenLabs/AVSpeech exactly as before.
    let kokoroEngine = KokoroTTSEngine()

    private func beginPause() {
        guard !didHoldPause else { return }
        wakeWordService?.pauseOtherAudio()
        didHoldPause = true
    }

    private func endPause() {
        guard didHoldPause else { return }
        didHoldPause = false
        wakeWordService?.resumeOtherAudio()
    }

    // MARK: - Public API

    /// Reset the ElevenLabs quota cache (call when API key changes or credits are added).
    func resetElevenLabsQuota() {
        elevenLabsQuotaExhausted = false
        print("🔊 ElevenLabs: Quota cache reset")
    }

    /// Speaks `text` with a verbal urgency: higher urgency speeds up the iOS voice and prepends a
    /// spoken cue (e.g. "Important: "). Universal — any caller can opt in; defaults to neutral.
    /// Mapping adapted from the neurobridge project.
    enum SpeechUrgency {
        case low, medium, high

        var rateMultiplier: Float {
            switch self {
            case .low: return 1.0
            case .medium: return 1.15
            case .high: return 1.3
            }
        }

        var prefix: String {
            switch self {
            case .low, .medium: return ""
            case .high: return "Important: "
            }
        }
    }

    /// Multiplier applied to the iOS speech rate for the current utterance (driven by urgency).
    private var activeRateMultiplier: Float = 1.0

    func speak(_ text: String, urgency: SpeechUrgency = .low, mirrorToHUD: Bool = true) async {
        guard !text.isEmpty else { return }
        activeRateMultiplier = urgency.rateMultiplier
        let text = urgency.prefix + text

        // Mirror spoken text to the in-lens HUD (additive; no-op without a display).
        // Callers that render a richer HUD treatment themselves pass mirrorToHUD: false.
        if mirrorToHUD { glassesDisplay?.showText(text, flashWhileInteractive: true) }

        // Silence if glasses-only mode is on and glasses aren't connected
        if Config.glassesOnlyAudio && !glassesConnected {
            print("🔊 TTS: Suppressed — glasses not connected (glasses-only mode)")
            return
        }

        // Route to speaker when glasses aren't connected (in playAndRecord sessions)
        if !glassesConnected {
            let session = AVAudioSession.sharedInstance()
            if session.category == .playAndRecord {
                try? session.overrideOutputAudioPort(.speaker)
            }
        }

        // Cancel any in-progress speech (including in-flight network requests)
        // Do this BEFORE bumping generation so stopSpeaking()'s increment doesn't
        // invalidate the generation we're about to capture.
        currentSpeechTask?.cancel()
        currentSpeechTask = nil
        streamSpeechTask?.cancel()
        streamSpeechTask = nil
        streamBuffer = ""
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        speechContinuation?.resume()
        speechContinuation = nil
        stopThinkingSound()

        // Bump generation AFTER cleanup — capture the new value
        speechGeneration += 1
        let gen = speechGeneration

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Check cancellation after the sleep — a newer speak() may have started
        guard !Task.isCancelled, gen == speechGeneration else {
            print("🔊 TTS: Skipped — generation changed or task cancelled (gen=\(gen) current=\(speechGeneration))")
            return
        }

        isSpeaking = true
        beginPause()

        // Wrap the actual speech work in a trackable task
        let task = Task { @MainActor [weak self] in
            guard let self, gen == self.speechGeneration else {
                print("🔊 TTS: Task skipped — generation stale")
                return
            }
            await self.speakThroughEngineChain(text: text, urgency: urgency, generation: gen)
        }
        currentSpeechTask = task

        // Wait for the speech task to finish
        await task.value

        // Only clear isSpeaking if this generation is still current
        if gen == speechGeneration {
            isSpeaking = false
            endPause()
            print("🔊 TTS: Finished speaking")
        }
    }

    // MARK: - Engine selection

    /// Speak `text` by walking the `TTSEngineSelector` fallback chain (ElevenLabs → Kokoro →
    /// AVSpeech): try each engine in turn, advancing to the next on failure. `.system` is the
    /// guaranteed terminal — it never throws, so the chain always produces audio (or is cancelled).
    private func speakThroughEngineChain(text: String, urgency: SpeechUrgency, generation gen: Int) async {
        let elevenLabsKey = Config.elevenLabsAPIKey
        // ElevenLabs is "ready" only with a key, online, and not quota-exhausted. Kokoro is "ready"
        // only with the model present *and* the binary compiled in (always false in the shipped
        // build → the chain collapses to ElevenLabs/AVSpeech exactly as before).
        let availability = TTSEngineSelector.Availability(
            elevenLabsReady: !elevenLabsKey.isEmpty
                && !elevenLabsQuotaExhausted
                && (reachability?.isOnline ?? true),
            kokoroReady: kokoroEngine.isReady
        )
        let chain = TTSEngineSelector.chain(
            preference: Config.ttsEnginePreference,
            availability: availability,
            urgency: urgency
        )
        print("🔊 TTS: Speaking \(text.prefix(60))... chain=\(chain.map(\.rawValue).joined(separator: "→"))\(elevenLabsQuotaExhausted ? " (ElevenLabs quota exhausted)" : "")")

        for engine in chain {
            guard !Task.isCancelled, gen == speechGeneration else {
                print("🔊 TTS: Cancelled mid-chain")
                return
            }
            do {
                try Task.checkCancellation()
                switch engine {
                case .elevenLabs:
                    try await speakWithElevenLabs(text: text, apiKey: elevenLabsKey)
                case .kokoro:
                    try await speakWithKokoro(text: text)
                case .system:
                    await speakWithiOS(text: text)
                }
                return  // engine succeeded
            } catch is CancellationError {
                print("🔊 TTS: Cancelled")
                return
            } catch {
                // Only advance to the next engine if we weren't cancelled AND this is still current.
                guard !Task.isCancelled, gen == speechGeneration else {
                    print("🔊 TTS: Cancelled during fallback")
                    return
                }
                print("🔊 TTS: \(engine.rawValue) failed (\(error)), trying next engine")
                continue
            }
        }
    }

    // MARK: - Kokoro on-device TTS

    /// Speak via the on-device Kokoro engine: synthesize a WAV off the main actor, then play it
    /// through the same path as ElevenLabs. Throws when the engine isn't ready (model absent or the
    /// binary isn't compiled in) or synthesis fails, so the caller falls through to the next engine.
    private func speakWithKokoro(text: String) async throws {
        let data = try await kokoroEngine.synthesize(text)
        try Task.checkCancellation()
        try await playAudioData(data)
    }

    // MARK: - Streaming TTS

    /// Buffer for accumulating streaming chunks until a sentence boundary.
    private var streamBuffer = ""
    private var streamSpeechTask: Task<Void, Never>?

    /// Queue a partial text chunk for streaming speech.
    /// Accumulates text and speaks at sentence boundaries (. ! ? newline).
    func speakStreaming(_ chunk: String) async {
        streamBuffer += chunk

        // Check for sentence boundary in buffer
        let sentenceEnders: [Character] = [".", "!", "?", "\n"]
        if let lastEnder = streamBuffer.lastIndex(where: { sentenceEnders.contains($0) }) {
            let speakableEnd = streamBuffer.index(after: lastEnder)
            let sentence = String(streamBuffer[streamBuffer.startIndex..<speakableEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            streamBuffer = String(streamBuffer[speakableEnd...])

            if !sentence.isEmpty {
                // Wait for any current speech to finish, then speak the sentence
                await streamSpeechTask?.value
                streamSpeechTask = Task {
                    await speak(sentence)
                }
            }
        }
    }

    /// Flush any remaining buffered text and speak it.
    func flushStreamBuffer() async {
        let remaining = streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        streamBuffer = ""
        if !remaining.isEmpty {
            await streamSpeechTask?.value
            await speak(remaining)
        }
        streamSpeechTask = nil
    }

    func stopSpeaking() {
        stopThinkingSound()
        // Bump generation so any in-flight delegate callbacks are ignored
        speechGeneration += 1
        currentSpeechTask?.cancel()
        currentSpeechTask = nil
        streamSpeechTask?.cancel()
        streamSpeechTask = nil
        streamBuffer = ""
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        endPause()
        speechContinuation?.resume()
        speechContinuation = nil
    }

    /// Soft bing — photo captured silently (e.g. during a meeting recording).
    /// Short, gentle, higher-pitched with a fast decay so it's unobtrusive.
    func playPhotoTone() {
        do {
            let toneData = try Self.generateToneData(frequency: 1200, duration: 0.12, sampleRate: 44100, peakVolume: 0.35)
            let player = try AVAudioPlayer(data: toneData)
            self.tonePlayer = player
            player.volume = 0.45
            player.prepareToPlay()
            player.play()
        } catch {
            print("🔊 Photo tone failed: \(error)")
        }
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

    /// Ascending "glasses connected" cue (counterpart to playDisconnectTone).
    func playConnectTone() {
        playTone(frequency: 660, duration: 0.10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.playTone(frequency: 990, duration: 0.14)
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
    private static func generateToneData(frequency: Double, duration: Double, sampleRate: Double, peakVolume: Double = 0.8) throws -> Data {
        let numSamples = Int(sampleRate * duration)
        var samples = [Int16]()
        samples.reserveCapacity(numSamples)

        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            // Apply a quick fade-in/fast-decay envelope to avoid clicks
            let envelope: Double
            let fadeIn = 0.008   // 8ms fade in
            let fadeOut = 0.04   // 40ms fade out (longer decay = softer, more bell-like)
            if t < fadeIn {
                envelope = t / fadeIn
            } else if t > duration - fadeOut {
                envelope = (duration - t) / fadeOut
            } else {
                envelope = 1.0
            }
            let sample = sin(2.0 * .pi * frequency * t) * envelope * peakVolume
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

        // Check cancellation after network wait — a newer speak() may have started
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let errorStr = String(data: data, encoding: .utf8) {
                print("🔊 ElevenLabs: Error \(statusCode): \(errorStr)")
                // Cache quota exhaustion so we skip ElevenLabs for the rest of this session
                if errorStr.contains("quota_exceeded") {
                    print("🔊 ElevenLabs: Quota exhausted — switching to iOS voice for this session")
                    elevenLabsQuotaExhausted = true
                }
            }
            throw TTSError.apiError(statusCode: statusCode)
        }

        // Play the MP3 audio
        try await playAudioData(data)
    }

    private func playAudioData(_ data: Data) async throws {
        // If glasses disconnected between network download and playback, discard the audio.
        // This closes the race where stopSpeaking() ran before audioPlayer was assigned.
        guard !Task.isCancelled else { return }
        guard !Config.glassesOnlyAudio || glassesConnected else {
            print("🔊 TTS: Discarding downloaded audio — glasses not connected (glasses-only mode)")
            return
        }

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

        // Pick the best available English voice: premium > enhanced > default
        let voice = Self.bestAvailableVoice()
        utterance.voice = voice
        print("🔊 iOS TTS: Using voice \(voice?.name ?? "system default") (\(voice?.identifier ?? "nil"), quality=\(voice?.quality.rawValue ?? -1))")

        let scaledRate = AVSpeechUtteranceDefaultSpeechRate * activeRateMultiplier
        utterance.rate = min(max(scaledRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speechContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    /// Resolve the iOS TTS voice — uses saved preference or auto-selects best available.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        // Use saved preference if set
        let preferred = Config.iosTTSVoiceId
        if !preferred.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: preferred) {
            return voice
        }

        // Auto-select: best quality English voice available
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = allVoices.filter { $0.language.hasPrefix("en") }

        // Sort by quality descending (premium=3, enhanced=2, default=1)
        let sorted = englishVoices.sorted { $0.quality.rawValue > $1.quality.rawValue }

        if let best = sorted.first, best.quality.rawValue >= 2 {
            return best
        }

        // Fallback to standard en-US
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// All English voices available on this device, grouped by quality.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
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

    // MARK: - Thinking Sound

    /// Play a subtle sound while the AI is processing.
    private var thinkingPlayer: AVAudioPlayer?
    private var thinkingTimer: Timer?

    func startThinkingSound() {
        stopThinkingSound()

        // Gentle ambient breath — filtered noise-like texture, not a bleep
        let sampleRate: Double = 44100
        let duration: Double = 1.2
        let amplitude: Float = 0.02
        let frameCount = Int(sampleRate * duration)

        var samples = [Float](repeating: 0, count: frameCount)
        // Layer several detuned low frequencies for a soft pad-like hum
        let freqs: [(Double, Float)] = [
            (120, 1.0),   // deep fundamental
            (180, 0.4),   // soft fifth
            (240, 0.15),  // quiet octave
        ]
        for i in 0..<frameCount {
            let t = Float(i) / Float(sampleRate)
            let progress = t / Float(duration)
            // Long, smooth fade in and out (no sharp attack)
            let envelope = sin(Float.pi * progress)
            var mix: Float = 0
            for (freq, level) in freqs {
                mix += level * sin(2 * Float.pi * Float(freq) * t)
            }
            samples[i] = amplitude * envelope * mix
        }

        // Convert to 16-bit PCM WAV
        let dataSize = frameCount * 2
        let headerSize = 44
        var wav = Data(count: headerSize + dataSize)

        // WAV header
        wav.replaceSubrange(0..<4, with: "RIFF".data(using: .ascii)!)
        var fileSize = UInt32(headerSize + dataSize - 8)
        wav.replaceSubrange(4..<8, with: Data(bytes: &fileSize, count: 4))
        wav.replaceSubrange(8..<12, with: "WAVE".data(using: .ascii)!)
        wav.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        var fmtSize: UInt32 = 16; wav.replaceSubrange(16..<20, with: Data(bytes: &fmtSize, count: 4))
        var audioFormat: UInt16 = 1; wav.replaceSubrange(20..<22, with: Data(bytes: &audioFormat, count: 2))
        var channels: UInt16 = 1; wav.replaceSubrange(22..<24, with: Data(bytes: &channels, count: 2))
        var sr: UInt32 = UInt32(sampleRate); wav.replaceSubrange(24..<28, with: Data(bytes: &sr, count: 4))
        var byteRate: UInt32 = UInt32(sampleRate) * 2; wav.replaceSubrange(28..<32, with: Data(bytes: &byteRate, count: 4))
        var blockAlign: UInt16 = 2; wav.replaceSubrange(32..<34, with: Data(bytes: &blockAlign, count: 2))
        var bitsPerSample: UInt16 = 16; wav.replaceSubrange(34..<36, with: Data(bytes: &bitsPerSample, count: 2))
        wav.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        var ds: UInt32 = UInt32(dataSize); wav.replaceSubrange(40..<44, with: Data(bytes: &ds, count: 4))

        for i in 0..<frameCount {
            var sample = Int16(max(-32768, min(32767, samples[i] * 32767)))
            wav.replaceSubrange((headerSize + i * 2)..<(headerSize + i * 2 + 2), with: Data(bytes: &sample, count: 2))
        }

        do {
            thinkingPlayer = try AVAudioPlayer(data: wav)
            thinkingPlayer?.volume = 0.35

            // Soft ambient breath every 2 seconds
            thinkingPlayer?.play()
            thinkingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    self?.thinkingPlayer?.currentTime = 0
                    self?.thinkingPlayer?.play()
                }
            }
        } catch {
            print("🔊 Thinking sound error: \(error)")
        }
    }

    /// Stop the thinking sound.
    func stopThinkingSound() {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        thinkingPlayer?.stop()
        thinkingPlayer = nil
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
