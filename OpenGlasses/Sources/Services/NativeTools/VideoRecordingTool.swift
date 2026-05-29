import Foundation

/// Allows the AI agent to start/stop video recording from the glasses camera.
/// Records video + audio from the glasses microphone with optional live transcription.
/// Recordings are saved locally to the Photos library with no time limit —
/// ideal for clinical interviews, meetings, or any long-form capture.
struct VideoRecordingTool: NativeTool {
    let name = "video_recording"
    let description = """
        Start or stop video recording from the smart glasses camera with audio. \
        Recordings include the glasses microphone audio and are saved to the local Photos library (Glasses album) with no time limit. \
        Optionally transcribes speech in real-time alongside the recording. \
        Use when the user says 'start recording', 'record this', 'film this', \
        'watch what I'm doing', 'stop recording', or 'save the video'. \
        For clinical interviews or meetings, enable transcription with transcribe=true.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "stop", "status"],
                "description": "Action to perform: start recording, stop recording (saves to Photos), or check status"
            ],
            "transcribe": [
                "type": "boolean",
                "description": "Enable live transcription alongside recording (default: true for interviews/meetings)"
            ]
        ],
        "required": ["action"]
    ]

    weak var cameraService: CameraService?
    weak var videoRecorder: VideoRecordingService?
    weak var medicalExportService: MedicalExportService?

    init(cameraService: CameraService, videoRecorder: VideoRecordingService,
         medicalExportService: MedicalExportService? = nil) {
        self.cameraService = cameraService
        self.videoRecorder = videoRecorder
        self.medicalExportService = medicalExportService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "Please specify an action: start, stop, or status."
        }
        guard let camera = cameraService, let recorder = videoRecorder else {
            return "Recording service not available."
        }

        switch action {
        case "start":
            let isRecording = await MainActor.run { recorder.isRecording }
            if isRecording {
                let duration = await MainActor.run { recorder.formattedDuration }
                return "Already recording (\(duration)). Say 'stop recording' when you're done."
            }

            // Ensure camera is streaming
            do {
                try await camera.ensurePermission()
                if await !MainActor.run(body: { camera.isStreaming }) {
                    try await camera.startStreaming()
                }
            } catch {
                return "Could not start camera: \(error.localizedDescription)"
            }

            // Default to transcription enabled
            let transcribe = args["transcribe"] as? Bool ?? true

            // Start recording with auto-save and optional transcription
            do {
                try await MainActor.run {
                    recorder.autoSaveToPhotos = true
                    recorder.autoTranscribe = transcribe
                    try recorder.startRecording(
                        from: camera.framePublisher,
                        bitrate: Config.recordingBitrate
                    )
                }
                var response = "Recording started with audio from the glasses microphone. The video will be saved to your Photos library when you stop."
                if transcribe {
                    response += " Live transcription is running — a text transcript will be saved alongside the video."
                }
                response += " Say 'stop recording' when you're done — there is no time limit."
                return response
            } catch {
                return "Could not start recording: \(error.localizedDescription)"
            }

        case "stop":
            let isRecording = await MainActor.run { recorder.isRecording }
            guard isRecording else {
                return "No recording in progress."
            }

            let duration = await MainActor.run { recorder.formattedDuration }
            let url = await recorder.stopRecording()
            let transcript = await MainActor.run { recorder.recordingTranscript }

            var response: String
            if url != nil {
                response = "Recording stopped (\(duration)). Video with audio saved to your Photos library in the Glasses album."
            } else {
                response = "Recording stopped (\(duration)) but the file could not be saved."
            }

            if !transcript.isEmpty {
                let wordCount = transcript.split(separator: " ").count
                response += " Transcript saved to Documents/Transcripts (\(wordCount) words)."

                // Auto-export if configured
                if Config.autoExportEnabled, let exportService = medicalExportService {
                    let config = FHIRConfig.fromDefaults()
                    if !config.baseURL.isEmpty && (MedicalPlatform(rawValue: config.platformType)?.usesFHIR ?? false) {
                        let exportResult = await exportService.exportToFHIR(
                            transcript: transcript,
                            duration: duration,
                            date: Date(),
                            config: config
                        )
                        if exportResult.success {
                            response += " Auto-exported to FHIR server."
                        } else {
                            response += " Auto-export failed: \(exportResult.message). You can export manually."
                        }
                    } else {
                        // Create file for sharing in the default format
                        let fileURL = exportService.createExportFile(
                            transcript: transcript,
                            duration: duration,
                            date: Date(),
                            format: Config.defaultExportFormat
                        )
                        if fileURL != nil {
                            response += " Export file created in \(Config.defaultExportFormat.rawValue) format."
                        }
                    }
                }

                // Include transcript for agent to summarize or share
                let previewLength = min(transcript.count, 2000)
                let preview = String(transcript.prefix(previewLength))
                let truncated = transcript.count > 2000 ? "\n\n[...transcript truncated, full version saved to file]" : ""
                response += "\n\n--- TRANSCRIPT ---\n\(preview)\(truncated)"
            }

            return response

        case "status":
            let isRecording = await MainActor.run { recorder.isRecording }
            if isRecording {
                let duration = await MainActor.run { recorder.formattedDuration }
                let transcript = await MainActor.run { recorder.recordingTranscript }
                var response = "Currently recording — \(duration) elapsed."
                if !transcript.isEmpty {
                    let wordCount = transcript.split(separator: " ").count
                    response += " Transcript: \(wordCount) words so far."
                }
                return response
            } else {
                return "Not currently recording."
            }

        default:
            return "Unknown action '\(action)'. Use start, stop, or status."
        }
    }
}
