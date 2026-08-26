import AVFoundation
import SwiftUI

/// Preserved meeting recordings: list, playback, transcript, and the record/stop control.
struct RecordingsView: View {
    @ObservedObject var store: RecordedSessionStore
    @ObservedObject var controller: SessionRecorderController
    @ObservedObject var audioRecorder: AudioRecordingService
    @State private var recordingError: String?

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Tap the record button to capture a meeting. Recordings and their transcripts appear here.")
                )
            } else {
                List {
                    ForEach(store.sessions) { session in
                        NavigationLink {
                            RecordedSessionDetailView(
                                session: session,
                                store: store,
                                controller: controller
                            )
                        } label: {
                            RecordedSessionRow(session: session)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                }
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                recordButton
            }
        }
        .alert("Recording failed", isPresented: Binding(
            get: { recordingError != nil },
            set: { if !$0 { recordingError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recordingError ?? "")
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if controller.isRecording {
                    await controller.stop()
                } else {
                    do {
                        try await controller.start()
                    } catch {
                        recordingError = error.localizedDescription
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.isRecording ? "stop.circle.fill" : "record.circle")
                if controller.isRecording {
                    Text(audioRecorder.formattedDuration)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .foregroundStyle(controller.isRecording ? OGTheme.errorLabel : Color.accentColor)
        }
        .accessibilityLabel("Record meeting")
        .accessibilityValue(controller.isRecording ? "Recording \(audioRecorder.formattedDuration)" : "Stopped")
        .accessibilityHint("Double-tap to start or stop recording.")
    }

    private func deleteSessions(at offsets: IndexSet) {
        let sessions = store.sessions
        for offset in offsets {
            let session = sessions[offset]
            controller.cancelTranscription(for: session.id)
            store.delete(session)
        }
    }
}

/// Sheet presentation wrapper for entry points that are not already in a navigation stack.
struct RecordingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecordedSessionStore
    let controller: SessionRecorderController
    let audioRecorder: AudioRecordingService

    var body: some View {
        NavigationStack {
            RecordingsView(store: store, controller: controller, audioRecorder: audioRecorder)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct RecordedSessionRow: View {
    let session: RecordedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.headline)

            HStack(spacing: 8) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(RecordingTimeFormatter.string(from: session.duration))
                Spacer()
                TranscriptionStateBadge(state: session.state)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct RecordedSessionDetailView: View {
    @ObservedObject private var store: RecordedSessionStore
    private let controller: SessionRecorderController
    private let initialSession: RecordedSession
    @StateObject private var playback: RecordingPlaybackController
    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44

    init(
        session: RecordedSession,
        store: RecordedSessionStore,
        controller: SessionRecorderController
    ) {
        self.initialSession = session
        self.store = store
        self.controller = controller
        _playback = StateObject(
            wrappedValue: RecordingPlaybackController(audioURL: store.audioURL(for: session))
        )
    }

    private var session: RecordedSession {
        store.sessions.first(where: { $0.id == initialSession.id }) ?? initialSession
    }

    private var canTranscribeAgain: Bool {
        guard session.state != .transcribing else { return false }
        let transcriptIsEmpty = session.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return session.state == .failed || session.state == .unavailable || transcriptIsEmpty
    }

    var body: some View {
        List {
            Section("Recording") {
                LabeledContent("Date") {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Duration") {
                    Text(RecordingTimeFormatter.string(from: session.duration))
                }

                HStack(spacing: 12) {
                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .frame(minWidth: tapTarget, minHeight: tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

                    Text(RecordingTimeFormatter.playbackTime(
                        elapsed: playback.elapsed,
                        duration: playback.duration
                    ))
                    .font(.system(.body, design: .monospaced))

                    Spacer()

                    ShareLink(item: store.audioURL(for: session)) {
                        Label("Share Audio", systemImage: "square.and.arrow.up")
                    }
                }

                if let failureReason = playback.failureReason {
                    Text(failureReason)
                        .font(.footnote)
                        .foregroundStyle(OGTheme.errorLabel)
                }
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    TranscriptionStateBadge(state: session.state)
                }

                if let failureReason = session.failureReason, !failureReason.isEmpty {
                    Text(failureReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No transcript available.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.transcript)
                        .textSelection(.enabled)
                }

                if canTranscribeAgain {
                    Button {
                        controller.transcribeAgain(session)
                    } label: {
                        Label("Transcribe Again", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Transcript")
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            playback.pause()
        }
    }
}

private struct TranscriptionStateBadge: View {
    let state: TranscriptionState

    var body: some View {
        HStack(spacing: 4) {
            if state == .transcribing {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(state.displayName)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(state.labelTint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript \(state.displayName)")
    }
}

private extension TranscriptionState {
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }

    /// Badge fill wash — the uncorrected status hue.
    var tint: Color {
        switch self {
        case .pending: return OGTheme.warn
        case .transcribing: return .blue
        case .done: return OGTheme.ok
        case .failed: return OGTheme.error
        case .unavailable: return .secondary
        }
    }

    /// Badge text colour — the WCAG-AA-audited label variant.
    var labelTint: Color {
        switch self {
        case .pending: return OGTheme.warnLabel
        case .transcribing: return .blue
        case .done: return OGTheme.okLabel
        case .failed: return OGTheme.errorLabel
        case .unavailable: return .secondary
        }
    }
}

private enum RecordingTimeFormatter {
    static func string(from interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func playbackTime(elapsed: TimeInterval, duration: TimeInterval) -> String {
        "\(string(from: elapsed)) / \(string(from: duration))"
    }
}

@MainActor
private final class RecordingPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var failureReason: String?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    init(audioURL: URL) {
        super.init()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            self.player = player
            self.duration = player.duration
            player.delegate = self
            player.prepareToPlay()
        } catch {
            failureReason = "The audio file could not be opened: \(error.localizedDescription)"
        }
    }

    deinit {
        progressTimer?.invalidate()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
        updateElapsed()
    }

    private func play() {
        guard let player else { return }
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        guard player.play() else {
            failureReason = "The audio file could not be played."
            return
        }
        isPlaying = true
        failureReason = nil
        startProgressTimer()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsed()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateElapsed() {
        elapsed = player?.currentTime ?? 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopProgressTimer()
            self.updateElapsed()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reason = error?.localizedDescription ?? "Unknown playback error"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopProgressTimer()
            self.failureReason = "The audio file could not be played: \(reason)"
        }
    }
}
