import Combine
import Foundation

enum SessionRecorderError: LocalizedError {
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Another recording is already in progress."
        }
    }
}

/// Orchestrates one preserved meeting recording: shared-engine startup (even when wake-word
/// listening is off), `AudioRecordingService` capture with live captions, then post-hoc
/// transcription through `RecordingTranscriber` with a pending → transcribing → done/failed
/// state machine persisted in `RecordedSessionStore`.
@MainActor
final class SessionRecorderController: ObservableObject {
    @Published private(set) var isRecording = false

    private let audioRecorder: AudioRecordingService
    private let wakeWordService: WakeWordService
    private let store: RecordedSessionStore
    private let transcriber: RecordingTranscriber

    private var startedAt: Date?
    private var startedEngineForRecording = false
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        audioRecorder: AudioRecordingService,
        wakeWordService: WakeWordService,
        store: RecordedSessionStore,
        transcriber: RecordingTranscriber
    ) {
        self.audioRecorder = audioRecorder
        self.wakeWordService = wakeWordService
        self.store = store
        self.transcriber = transcriber
    }

    func start() async throws {
        guard !isRecording, !audioRecorder.isRecording else {
            throw SessionRecorderError.alreadyRecording
        }

        let engineWasRunning = wakeWordService.getAudioEngine()?.isRunning == true
        try await wakeWordService.ensureAudioEngineRunningForConsumers()

        do {
            try audioRecorder.startRecording()
            startedEngineForRecording = !engineWasRunning && !wakeWordService.isListening
            startedAt = Date()
            isRecording = true
        } catch {
            if !engineWasRunning, !wakeWordService.isListening {
                wakeWordService.stopListening()
            }
            throw error
        }
    }

    func stop() async {
        guard isRecording else { return }

        let sessionStart = startedAt ?? Date().addingTimeInterval(-audioRecorder.recordingDuration)
        let savedURL = await audioRecorder.stopRecording()
        let duration = audioRecorder.recordingDuration
        let liveTranscript = audioRecorder.recordingTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        isRecording = false
        startedAt = nil
        if startedEngineForRecording, !wakeWordService.isListening {
            wakeWordService.stopListening()
        }
        startedEngineForRecording = false

        guard let savedURL else { return }

        let session = RecordedSession(
            id: UUID(),
            title: Self.title(at: sessionStart),
            startedAt: sessionStart,
            duration: duration,
            audioFileName: savedURL.lastPathComponent,
            transcript: liveTranscript,
            state: .pending,
            failureReason: nil
        )
        store.add(session)
        beginTranscription(for: session)
    }

    func transcribeAgain(_ session: RecordedSession) {
        guard transcriptionTasks[session.id] == nil,
              let current = store.sessions.first(where: { $0.id == session.id }) else {
            return
        }
        beginTranscription(for: current)
    }

    func cancelTranscription(for sessionID: UUID) {
        transcriptionTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func beginTranscription(for session: RecordedSession) {
        let task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transcriptionTasks[session.id] = nil }

            var inProgress = session
            inProgress.state = .transcribing
            inProgress.failureReason = nil
            self.store.update(inProgress)

            let outcome = await self.transcriber.transcribe(
                fileURL: self.store.audioURL(for: inProgress)
            )
            guard !Task.isCancelled else { return }

            let current = self.store.sessions.first(where: { $0.id == inProgress.id }) ?? inProgress
            let completed: RecordedSession
            switch outcome {
            case .success(let transcript):
                completed = current.applyingTranscription(transcript, state: .done)
            case .failure(let reason):
                completed = current.applyingTranscription(
                    "",
                    state: .failed,
                    failureReason: reason
                )
            case .unavailable(let reason):
                completed = current.applyingTranscription(
                    "",
                    state: .unavailable,
                    failureReason: reason
                )
            }
            self.store.update(completed)
        }
        transcriptionTasks[session.id] = task
    }

    private static func title(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Recording — \(formatter.string(from: date))"
    }
}
