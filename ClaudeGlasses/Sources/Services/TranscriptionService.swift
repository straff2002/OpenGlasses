import Foundation
import AVFoundation
import Speech

/// On-device speech transcription using iOS Speech Recognition
/// For production, consider using WhisperKit for better accuracy
@MainActor
class TranscriptionService: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var currentTranscription: String = ""
    @Published var errorMessage: String?

    var onTranscriptionComplete: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 2.0

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func startRecording() {
        guard !isRecording else { return }

        do {
            try setupAndStartRecording()
            isRecording = true
            print("Recording started...")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRecording = false

        if !currentTranscription.isEmpty {
            let finalText = currentTranscription
            currentTranscription = ""
            onTranscriptionComplete?(finalText)
        }
    }

    private func setupAndStartRecording() throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try audioSession.setActive(true)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw TranscriptionError.setupFailed("Could not create recognition request")
        }

        recognitionRequest.shouldReportPartialResults = true

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw TranscriptionError.setupFailed("Could not create audio engine")
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result = result {
            currentTranscription = result.bestTranscription.formattedString
            resetSilenceTimer()

            if result.isFinal {
                stopRecording()
            }
        }

        if let error = error {
            print("Transcription error: (error.localizedDescription)")
            stopRecording()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopRecording()
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case setupFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .setupFailed(let msg): return "Setup failed: (msg)"
        case .permissionDenied: return "Speech recognition permission denied"
        }
    }
}
