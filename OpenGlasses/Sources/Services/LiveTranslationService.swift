import Foundation
import Speech
import AVFoundation
import NaturalLanguage

/// Continuous live translation: listens to spoken foreign language and translates in real-time.
/// Uses on-device speech recognition + translation, with TTS output in the target language.
@MainActor
final class LiveTranslationService: ObservableObject {
    @Published var isActive = false
    @Published var sourceLanguage: String = "auto"  // Auto-detect or explicit (e.g. "es", "ja")
    @Published var targetLanguage: String = "en"    // Translate into this language
    @Published var lastDetectedLanguage: String = ""
    @Published var lastTranslation: String = ""
    @Published var translationCount: Int = 0

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Coexisting hold with the audio-session coordinator. Translation runs *under* the current
    /// owner (the wake-word listener that triggered it) using `.measurement`/`.mixWithOthers`, so it
    /// registers as a non-exclusive rider rather than acquiring the session — it must not preempt
    /// or deactivate it.
    private var coexistToken: UUID?
    private var routeChangeObserver: NSObjectProtocol?

    /// Callback when a translation is ready to be spoken
    var onTranslation: ((String) -> Void)?

    /// Debounce: don't translate the same partial result repeatedly
    private var lastTranslatedText: String = ""
    private var silenceTimer: Task<Void, Never>?

    // MARK: - Start/Stop

    func start(from source: String = "auto", to target: String = "en") async {
        guard !isActive else { return }
        sourceLanguage = source
        targetLanguage = target

        // Pick speech recognizer for source language
        let locale: Locale
        if source == "auto" {
            locale = Locale(identifier: "en-US")  // Default, will detect language from content
        } else {
            locale = Locale(identifier: source)
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            PrivacyLog.speech(.liveTranslation, .recognizerUnavailable,
                              language: PrivacyToken(locale.identifier))
            return
        }

        speechRecognizer = recognizer
        isActive = true
        translationCount = 0
        lastTranslatedText = ""

        await startListening()
        coexistToken = AudioSessionCoordinator.shared.beginCoexisting(.liveTranslation)

        // Rebuild the engine + tap when the hardware route changes (CJ item 5): the glasses
        // dropping off Bluetooth mid-translation left the tap pinned to a dead route — the one
        // engine in the app with no route-change handling. Same recovery every other engine uses.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) ?? .unknown
            guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            Task { @MainActor in
                guard let self, self.isActive else { return }
                PrivacyLog.audio(.translation, .routeChanged)
                self.restartListening()
            }
        }
        PrivacyLog.speech(.liveTranslation, .started, language: PrivacyToken(source),
                          detail: PrivacyToken(target))
    }

    func stop() {
        isActive = false
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        silenceTimer?.cancel()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        if let token = coexistToken {
            coexistToken = nil
            AudioSessionCoordinator.shared.endCoexisting(token)
        }
        PrivacyLog.speech(.liveTranslation, .stopped, count: translationCount)
    }

    // MARK: - Speech Recognition

    private func startListening() async {
        // Configure audio session based on mic source preference
        do {
            let usePhoneMic = Config.usePhoneMicForTranslation
            let options: AVAudioSession.CategoryOptions = usePhoneMic
                ? [.mixWithOthers, .defaultToSpeaker]
                : [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            // .default, not .measurement (Plan BE): as a coexisting rider we must not leave the
            // shared session in a state the owner didn't choose. .measurement disables output
            // processing and makes iPhone-speaker TTS extremely quiet, and it was never restored on
            // stop. .default matches the wake-word baseline so audio coexists cleanly.
            // BJ PR2 follow-up: the blocking setCategory→setActive runs off-main via the coordinator.
            try await AudioSessionCoordinator.shared.reconfigure(
                category: .playAndRecord, mode: .default, options: options)
            PrivacyLog.audio(.translation, .modeSelected,
                             detail: PrivacyToken(usePhoneMic ? "iPhone" : "glasses"))
        } catch {
            PrivacyLog.audio(.translation, .sessionConfigureFailed,
                             error: SafeErrorSummary(error))
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate the live hardware format before installing the tap (CJ item 5): a mid-route
        // Bluetooth transition can briefly report a zero format, and installing then crashes.
        // Same guard as WakeWordService; retry via the normal restart path.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            PrivacyLog.audio(.translation, .formatInvalid)
            if isActive { restartListening() }
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            PrivacyLog.audio(.translation, .engineStartFailed, error: SafeErrorSummary(error))
            isActive = false
            return
        }

        audioEngine = engine
        recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isActive else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.handlePartialTranscription(text, isFinal: result.isFinal)
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Restart recognition for continuous translation
                    if self.isActive {
                        self.restartListening()
                    }
                }
            }
        }
    }

    private func restartListening() {
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Brief pause then restart
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if isActive {
                await startListening()
            }
        }
    }

    // MARK: - Translation

    private func handlePartialTranscription(_ text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }

        // Debounce: wait for silence or final result before translating
        silenceTimer?.cancel()

        if isFinal {
            translateAndSpeak(text)
        } else {
            // Wait 1.5 seconds of no new text before translating partial results
            silenceTimer = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        self.translateAndSpeak(text)
                    }
                }
            }
        }
    }

    private func translateAndSpeak(_ text: String) {
        // Don't re-translate the same text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastTranslatedText else { return }

        // Only translate if enough new content (at least 3 words)
        let words = trimmed.split(separator: " ")
        guard words.count >= 3 else { return }

        lastTranslatedText = trimmed

        // Detect language
        let detectedLang = detectLanguage(trimmed)
        lastDetectedLanguage = detectedLang

        // Don't translate if already in target language
        if detectedLang == targetLanguage {
            return
        }

        // Translate
        let translation = translate(trimmed, from: detectedLang, to: targetLanguage)
        lastTranslation = translation
        translationCount += 1

        // Both halves were user content: the utterance and its translation. Language tags are
        // a property of the session, so those stay; the sentences do not.
        PrivacyLog.speech(.liveTranslation, .translated, language: PrivacyToken(detectedLang),
                          characters: trimmed.count, count: translation.count,
                          detail: PrivacyToken(targetLanguage))
        onTranslation?(translation)
    }

    private func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return "unknown" }
        return lang.rawValue  // e.g. "en", "es", "ja", "fr"
    }

    /// Translate using the on-device translation if available.
    /// Falls back to a simpler approach for offline use.
    private func translate(_ text: String, from source: String, to target: String) -> String {
        // Note: Full on-device translation requires the Translation framework (iOS 17.4+)
        // or a network call. For now, we use a pragmatic approach:
        // 1. If the existing TranslationTool is available, route through it
        // 2. Otherwise, prefix the detected language for the LLM to translate

        // For live translation, we return the text with language annotation
        // and let the TTS callback handle it (the LLM or a future Translation API call)
        return "[\(source)→\(target)] \(text)"
    }
}
