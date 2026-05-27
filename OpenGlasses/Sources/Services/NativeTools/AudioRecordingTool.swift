import Foundation

/// AI agent tool to start/stop audio-only recording with live transcription and meeting assistance.
/// Much lighter than video recording — no camera, no H.264, pure AAC audio saved as .m4a.
struct AudioRecordingTool: NativeTool {
    let name = "audio_recording"
    let description = """
        Start or stop audio-only recording from the glasses/phone microphone. \
        Saves an .m4a file to Documents/Recordings with live transcription running alongside. \
        The meeting assistant summarises the transcript and suggests questions every 60 seconds \
        via lock screen notifications. \
        While recording, saying 'take a picture' captures a photo whose description is added \
        to the transcript for full visual context. \
        Far lighter on battery than video recording — use for meetings, interviews, lectures, \
        or any session where video is not needed. \
        Use when the user says 'record audio', 'record this meeting', 'record this conversation', \
        'start audio recording', 'stop recording', or 'save the audio'.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "stop", "status"],
                "description": "start recording, stop and save, or check current status"
            ]
        ],
        "required": ["action"]
    ]

    weak var audioRecorder: AudioRecordingService?

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "Please specify an action: start, stop, or status."
        }
        guard let recorder = audioRecorder else {
            return "Audio recording service not available."
        }

        switch action {
        case "start":
            let isRecording = await MainActor.run { recorder.isRecording }
            if isRecording {
                let duration = await MainActor.run { recorder.formattedDuration }
                return "Already recording audio (\(duration)). Say 'stop recording' when done."
            }
            do {
                try await MainActor.run {
                    recorder.autoSaveToFiles = true
                    recorder.autoTranscribe = true
                    try recorder.startRecording()
                }
                return "Audio recording started. Live transcription and meeting assistant are running — you'll get periodic summaries and suggested questions on your lock screen. Say 'stop recording' when done. You can also say 'take a picture' at any time to add a visual note to the transcript."
            } catch {
                return "Could not start audio recording: \(error.localizedDescription)"
            }

        case "stop":
            let isRecording = await MainActor.run { recorder.isRecording }
            guard isRecording else {
                return "No audio recording in progress."
            }
            let duration = await MainActor.run { recorder.formattedDuration }
            let url = await recorder.stopRecording()
            let transcript = await MainActor.run { recorder.recordingTranscript }

            var response: String
            if let url {
                response = "Recording stopped (\(duration)). Audio saved to \(url.lastPathComponent)."
            } else {
                response = "Recording stopped (\(duration)) but the file could not be saved."
            }

            if !transcript.isEmpty {
                let wordCount = transcript.split(separator: " ").count
                response += " Transcript: \(wordCount) words captured."
                let previewLength = min(transcript.count, 2000)
                let preview = String(transcript.prefix(previewLength))
                let truncated = transcript.count > 2000 ? "\n[...truncated]" : ""
                response += "\n\n--- TRANSCRIPT ---\n\(preview)\(truncated)"
            }
            return response

        case "status":
            let isRecording = await MainActor.run { recorder.isRecording }
            if isRecording {
                let duration = await MainActor.run { recorder.formattedDuration }
                let transcript = await MainActor.run { recorder.recordingTranscript }
                var response = "Recording audio — \(duration) elapsed."
                if !transcript.isEmpty {
                    response += " \(transcript.split(separator: " ").count) words transcribed so far."
                }
                return response
            }
            return "Not currently recording."

        default:
            return "Unknown action '\(action)'. Use start, stop, or status."
        }
    }
}
