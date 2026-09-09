import Foundation

/// Maps allowed remote commands onto the existing device services (Plan BH). The stage bodies are
/// injected as `@MainActor` closures (house seam pattern), so the sequencing rules are
/// unit-testable with recorder closures and fresh instances — never `.shared`.
///
/// Non-negotiables enforced here:
/// - Every **capture** command first asks the user via the confirmation coordinator (the
///   `HighImpactToolPolicy` UX applied to remote actuation), then **announces itself** (TTS)
///   before the sensor turns on — or, for a transcript read, before recorded speech leaves the
///   device. Nothing remote is ever silent.
/// - `deviceCapabilities` reports what is *currently* true, not what the app theoretically has —
///   the closure reads live service state.
@MainActor
final class RemoteCommandExecutor {

    enum Outcome: Equatable {
        case success([String: String])
        case declined            // user rejected the capture confirmation
        case failed(String)

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case (.success(let a), .success(let b)): return a == b
            case (.declined, .declined): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    struct Deps {
        /// Ask the user to approve a remote capture ("Remote agent wants to …"). Returns approval.
        var confirmCapture: @MainActor (String) async -> Bool
        /// Speak the pre-capture announcement. Runs after approval, before the sensor starts.
        var announce: @MainActor (String) async -> Void

        var capturePhoto: @MainActor () async throws -> Void
        var startAudioRecording: @MainActor () throws -> Void
        var stopAudioRecording: @MainActor () async -> String?
        var startVideo: @MainActor () async throws -> Void
        var stopVideo: @MainActor () async -> String?
        var startTranslation: @MainActor (String?, String?) -> Void
        var stopTranslation: @MainActor () -> Void
        var startTranscription: @MainActor () -> Void
        var stopTranscription: @MainActor () -> Void
        var speak: @MainActor (String) async -> Void
        /// Returns false when no display is present/supported.
        var displayShow: @MainActor (String, String?) -> Bool
        var displayClear: @MainActor () -> Void
        var deviceStatus: @MainActor () -> [String: String]
        var deviceCapabilities: @MainActor () -> [String: String]
        var addNote: @MainActor (String) async throws -> String
        var getTranscript: @MainActor () -> String
        var stopAll: @MainActor () async -> Void
    }

    private let deps: Deps

    init(deps: Deps) {
        self.deps = deps
    }

    func execute(_ command: RemoteGlassesCommand) async -> Outcome {
        // Capture-class commands: confirm, then announce, then act — in that order.
        if command.commandClass == .capture {
            guard await deps.confirmCapture(captureSummary(for: command)) else { return .declined }
            await deps.announce(captureAnnouncement(for: command))
        }

        do {
            switch command {
            case .capturePhoto:
                try await deps.capturePhoto()
                return .success(["captured": "true"])
            case .startAudioRecording:
                try deps.startAudioRecording()
                return .success(["recording": "audio"])
            case .stopAudioRecording:
                let file = await deps.stopAudioRecording()
                return .success(file.map { ["stopped": "audio", "file": $0] } ?? ["stopped": "audio"])
            case .startVideo:
                try await deps.startVideo()
                return .success(["recording": "video"])
            case .stopVideo:
                let file = await deps.stopVideo()
                return .success(file.map { ["stopped": "video", "file": $0] } ?? ["stopped": "video"])
            case .startTranslation(let source, let target):
                deps.startTranslation(source, target)
                return .success(["translation": "started"])
            case .stopTranslation:
                deps.stopTranslation()
                return .success(["translation": "stopped"])
            case .startTranscription:
                deps.startTranscription()
                return .success(["transcription": "started"])
            case .stopTranscription:
                deps.stopTranscription()
                return .success(["transcription": "stopped"])
            case .speak(let text):
                await deps.speak(text)
                return .success(["spoke": "true"])
            case .displayShow(let text, let icon):
                guard deps.displayShow(text, icon) else {
                    return .failed("No in-lens display available on this device")
                }
                return .success(["displayed": "true"])
            case .displayClear:
                deps.displayClear()
                return .success(["cleared": "true"])
            case .deviceStatus:
                return .success(deps.deviceStatus())
            case .deviceCapabilities:
                return .success(deps.deviceCapabilities())
            case .addNote(let text):
                let result = try await deps.addNote(text)
                return .success(["note": result])
            case .getTranscript:
                return .success(["transcript": deps.getTranscript()])
            case .stopAll:
                await deps.stopAll()
                return .success(["stopped": "all"])
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func captureSummary(for command: RemoteGlassesCommand) -> String {
        switch command {
        case .capturePhoto: return "Remote agent wants to take a photo"
        case .startAudioRecording: return "Remote agent wants to start an audio recording"
        case .startVideo: return "Remote agent wants to start a video recording"
        case .startTranslation: return "Remote agent wants to start live translation"
        case .startTranscription: return "Remote agent wants to start transcription"
        case .getTranscript: return "Remote agent wants to read the recent transcript"
        default: return "Remote agent wants to use a sensor"
        }
    }

    private func captureAnnouncement(for command: RemoteGlassesCommand) -> String {
        switch command {
        case .capturePhoto: return "Remote photo"
        case .startAudioRecording: return "Remote audio recording started"
        case .startVideo: return "Remote video recording started"
        case .startTranslation: return "Remote translation started"
        case .startTranscription: return "Remote transcription started"
        case .getTranscript: return "Remote transcript read"
        default: return "Remote capture started"
        }
    }
}
