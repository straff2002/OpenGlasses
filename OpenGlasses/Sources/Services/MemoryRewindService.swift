import Foundation
import Speech
import AVFoundation

/// Rolling audio buffer that stores the last N minutes of ambient audio.
/// On demand, transcribes the buffer and provides an AI-summarized recap.
/// "What did they just say?" → transcribes recent audio → summarizes.
@MainActor
class MemoryRewindService: ObservableObject {
    @Published var isActive = false
    @Published var bufferDurationMinutes: Double = 0

    /// How many minutes of audio to keep (configurable)
    var maxBufferMinutes: Double = 10.0

    /// All rolling-buffer state is confined to `ingestQueue` — the audio thread writes and the main
    /// actor reads only by hopping here, so the lazily-sized ring is never accessed concurrently.
    private let ingestQueue = DispatchQueue(label: "memory.rewind.ingest", qos: .utility)
    private nonisolated(unsafe) var ring: RewindRingBuffer?      // ingestQueue only
    private nonisolated(unsafe) var bufferSampleRate: Double = 16000   // ingestQueue only
    private nonisolated(unsafe) var ringMaxMinutes: Double = 10        // ingestQueue only
    private var bufferStartTime: Date?
    /// Periodically refreshes the published duration off the audio hot path.
    private var durationTimer: Timer?

    // Pure (no main-actor state) — nonisolated so the ingest-queue paths can call it.
    private nonisolated static func bytesPerMinute(at rate: Double) -> Int { Int(rate) * 2 * 60 }

    /// Reference to wake word service for audio tap
    weak var wakeWordService: WakeWordService?

    private let recognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)

    // MARK: - Public API

    func start() {
        guard !isActive else { return }
        isActive = true
        bufferStartTime = Date()

        let maxMinutes = maxBufferMinutes
        ingestQueue.async { [weak self] in
            self?.ring = nil                 // (re)created on the first buffer, sized to its rate
            self?.ringMaxMinutes = maxMinutes
        }

        // Ingest directly on the audio thread — no per-buffer main-actor hop. Conversion is bulk
        // (PCMConverter) and the ring append is O(bytes appended); the published duration is
        // refreshed on a 1s timer instead of once per buffer.
        wakeWordService?.addAudioBufferConsumer(id: "memory_rewind") { [weak self] buffer in
            self?.ingest(buffer)
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDuration()
        }

        PrivacyLog.speech(.memoryRewind, .started, count: Int(maxBufferMinutes))
    }

    func stop() {
        isActive = false
        wakeWordService?.removeAudioBufferConsumer(id: "memory_rewind")
        durationTimer?.invalidate()
        durationTimer = nil
        ingestQueue.async { [weak self] in
            self?.ring?.reset()
            self?.ring = nil
        }
        bufferStartTime = nil
        bufferDurationMinutes = 0
        PrivacyLog.speech(.memoryRewind, .stopped)
    }

    // nonisolated: only touches ingest-queue state and hops to @MainActor for the UI update,
    // so it's safe to call from the nonisolated duration timer.
    private nonisolated func refreshDuration() {
        ingestQueue.async { [weak self] in
            guard let self, let ring = self.ring else { return }
            let minutes = Double(ring.count) / Double(Self.bytesPerMinute(at: self.bufferSampleRate))
            Task { @MainActor in self.bufferDurationMinutes = minutes }
        }
    }

    /// Transcribe the last N minutes (or all buffered audio) and return text
    func rewind(lastMinutes: Double = 2.0) async -> String {
        guard isActive else {
            return "Memory rewind is not active. Enable it in settings first."
        }

        let minutesToTranscribe = min(lastMinutes, max(bufferDurationMinutes, 0))

        // Read the most recent window off the ingest queue (where the ring lives).
        let (recentAudio, rate): (Data, Double) = await withCheckedContinuation { continuation in
            ingestQueue.async { [weak self] in
                guard let self, let ring = self.ring else {
                    continuation.resume(returning: (Data(), 16000))
                    return
                }
                let bytesPerMin = Self.bytesPerMinute(at: self.bufferSampleRate)
                // `minutesToTranscribe` is 0 when the fraction is < 1 min; fall back to the whole ring.
                let requested = minutesToTranscribe >= 1 ? Int(minutesToTranscribe) * bytesPerMin : ring.count
                continuation.resume(returning: (ring.snapshotSuffix(requested), self.bufferSampleRate))
            }
        }

        guard !recentAudio.isEmpty else {
            return "No audio buffered yet. Keep it running for a bit."
        }

        PrivacyLog.speech(.memoryRewind, .started, count: Int(minutesToTranscribe),
                          bytes: recentAudio.count, detail: PrivacyToken("transcribe"))

        // Convert raw PCM data to a WAV file for speech recognition
        let wavData = createWAV(from: recentAudio, sampleRate: rate)

        do {
            let transcript = try await transcribeAudio(wavData)
            if transcript.isEmpty {
                return "I couldn't make out any speech in the last \(Int(minutesToTranscribe)) minutes of audio."
            }
            return "Here's what was said in the last \(Int(minutesToTranscribe)) minutes:\n\n\(transcript)\n\nThe LLM should now summarize this for the user in a natural, conversational way."
        } catch {
            return "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Audio Buffer Management

    /// Called on the audio-render thread. Bulk-converts float32 → linear16 (one allocation) and
    /// appends into the ring on `ingestQueue`; the whole-buffer memmove of the old design is gone.
    private nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let pcm = PCMConverter.linear16Mono(from: buffer)
        guard !pcm.isEmpty else { return }
        ingestQueue.async { [weak self] in
            guard let self else { return }
            self.bufferSampleRate = rate
            if self.ring == nil {
                let capacity = max(1, Int(self.ringMaxMinutes * Double(Self.bytesPerMinute(at: rate))))
                self.ring = RewindRingBuffer(capacity: capacity)
            }
            self.ring?.append(pcm)
        }
    }

    // MARK: - Transcription

    private func transcribeAudio(_ wavData: Data) async throws -> String {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw RewindError.recognizerUnavailable
        }

        // Write to temp file (SFSpeechURLRecognitionRequest needs a file URL)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("rewind_\(UUID().uuidString).wav")
        // Rolling-buffer audio is sensitive — encrypt the on-disk temp file at rest. It is
        // deleted as soon as recognition finishes (see `defer`).
        try wavData.write(to: tempURL, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    // BS P1: rolling-buffer audio is mostly ambience — drop unmistakable
                    // silence-decode artifacts before they read back as "what was said".
                    let text = TranscriptGuard.filter(
                        result.bestTranscription.formattedString,
                        expectedLocaleIdentifier: Config.speechRecognitionLocale) ?? ""
                    continuation.resume(returning: text)
                }
            }
        }
    }

    // MARK: - WAV Creation

    private func createWAV(from pcmData: Data, sampleRate: Double) -> Data {
        var data = Data()
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })   // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits/sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(pcmData)

        return data
    }
}

enum RewindError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognizer not available"
        }
    }
}
