import Foundation
import Speech
import Combine

/// Provides real-time ambient captions — continuous transcription of surrounding speech.
/// Runs independently of the wake word / AI conversation pipeline.
/// Subscribes to audio buffers from WakeWordService's shared audio engine.
@MainActor
class AmbientCaptionService: ObservableObject {
    @Published var isActive = false
    @Published var currentCaption = ""
    @Published var captionHistory: [CaptionEntry] = []

    struct CaptionEntry: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Presence-suspended (Plan W v2): captions stay user-`isActive` but the recognition session is
    /// torn down while the user is *away* (disconnected/backgrounded), auto-resuming on return. Never
    /// triggered by mere idle — a user reading captions silently is still engaged.
    private(set) var presenceSuspended = false

    /// Reference to the wake word service for audio buffer forwarding
    weak var wakeWordService: WakeWordService?

    /// Set by AppState — the live caption line is mirrored to the in-lens HUD when the
    /// Glasses Display feature is on. No-ops on glasses without a display.
    weak var glassesDisplay: GlassesDisplayService?

    /// Previous buffer forwarder (if transcription was using it)
    private var previousForwarder: ((AVAudioPCMBuffer) -> Void)?

    /// Timer to detect silence and finalize captions
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 2.0

    /// Max history entries to keep
    private let maxHistory = 50

    /// Rolling transcript for current utterance
    private var lastFinalizedText = ""

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Public API

    func start() {
        guard !isActive else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("🎙️ Captions: Speech recognizer not available")
            return
        }

        isActive = true
        currentCaption = ""
        startRecognitionSession()
        print("🎙️ Ambient captions started")
    }

    func stop() {
        isActive = false
        presenceSuspended = false
        stopRecognitionSession()
        currentCaption = ""
        glassesDisplay?.clear()
        print("🎙️ Ambient captions stopped")
    }

    /// Presence-aware suspend (Plan W v2): a user-started caption stream pauses only when the user is
    /// fully *away* (disconnected/backgrounded) — never on mere idle, since they may be silently
    /// reading. Keeps `isActive` true so it knows to resume. No-op unless captions are active.
    func suspendForPresence() {
        guard isActive, !presenceSuspended else { return }
        presenceSuspended = true
        stopRecognitionSession()
        currentCaption = ""
        glassesDisplay?.clear()
        print("🎙️ Ambient captions suspended (presence away)")
    }

    /// Resume a presence-suspended caption stream when the user returns. No-op otherwise.
    func resumeForPresence() {
        guard isActive, presenceSuspended else { return }
        presenceSuspended = false
        startRecognitionSession()
        print("🎙️ Ambient captions resumed (presence)")
    }

    func clearHistory() {
        captionHistory.removeAll()
    }

    // MARK: - Recognition Session

    private func startRecognitionSession() {
        // Plan W v2: never (re)start while presence-suspended — guards the continuous-recognition
        // self-restart paths (final-result / no-speech / error) from reviving a suspended stream.
        guard !presenceSuspended else { return }
        stopRecognitionSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        // Hook into the shared audio engine's buffer stream (named consumer)
        wakeWordService?.addAudioBufferConsumer(id: "ambient_captions") { [weak self] buffer in
            Task { @MainActor in
                self?.recognitionRequest?.append(buffer)
            }
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.isActive else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.currentCaption = text
                    self.glassesDisplay?.showText(text)
                    self.resetSilenceTimer()

                    if result.isFinal {
                        self.finalizeCaption(text)
                        // Restart for continuous recognition
                        if self.isActive {
                            self.startRecognitionSession()
                        }
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    // Ignore cancellation errors and "no speech detected"
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        // No speech detected — restart
                        if self.isActive {
                            self.restartAfterDelay()
                        }
                    } else if nsError.code != 216 { // 216 = cancelled
                        print("🎙️ Captions error: \(error.localizedDescription)")
                        if self.isActive {
                            self.restartAfterDelay()
                        }
                    }
                }
            }
        }
    }

    private func stopRecognitionSession() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        wakeWordService?.removeAudioBufferConsumer(id: "ambient_captions")
    }

    private func restartAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if self.isActive {
                self.startRecognitionSession()
            }
        }
    }

    // MARK: - Caption Management

    /// Inject a visual description (photo caption) into the caption history.
    /// Used when a photo is taken during an audio recording so the meeting
    /// transcript and assistant have context about what was seen.
    func insertVisualNote(_ description: String) {
        let note = "[Visual: \(description)]"
        let entry = CaptionEntry(text: note, timestamp: Date())
        captionHistory.insert(entry, at: 0)
        if captionHistory.count > maxHistory {
            captionHistory = Array(captionHistory.prefix(maxHistory))
        }
        print("🎙️ Visual note inserted into caption history")
    }

    private func finalizeCaption(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // Only add if it's meaningfully different from the last finalized text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastFinalizedText else { return }

        lastFinalizedText = trimmed
        let entry = CaptionEntry(text: trimmed, timestamp: Date())
        captionHistory.insert(entry, at: 0)

        // Trim history
        if captionHistory.count > maxHistory {
            captionHistory = Array(captionHistory.prefix(maxHistory))
        }

        currentCaption = ""
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.currentCaption.isEmpty {
                    self.finalizeCaption(self.currentCaption)
                }
            }
        }
    }
}
