import Foundation

/// Allows the AI agent to export transcripts and recordings to medical platforms.
/// Supports FHIR R4 upload, PDF generation, and share sheet for manual sharing.
/// Use when the user says "export the transcript", "send to my EMR", "share the recording",
/// or "upload to the health record".
struct MedicalExportTool: NativeTool {
    let name = "medical_export"
    let description = """
        Export a clinical transcript or recording to a medical platform or share it manually. \
        Supports FHIR R4 (Epic, Cerner, MEDITECH), PDF, HL7, and plain text formats. \
        Can upload directly to a configured FHIR server or prepare a file for sharing via AirDrop, email, or Files. \
        Use when the user says 'export the transcript', 'send to the EMR', 'share the recording', \
        'upload to my health record', or 'send the notes to the doctor'. \
        Requires Medical Compliance mode or an explicit export request.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["export_fhir", "export_file", "share", "status"],
                "description": "Action: export_fhir (upload to FHIR server), export_file (create file for sharing), share (open share sheet), status (check configuration)"
            ],
            "format": [
                "type": "string",
                "enum": ["text", "pdf", "fhir_json", "hl7"],
                "description": "File format for export_file action (default: text)"
            ],
            "transcript": [
                "type": "string",
                "description": "Transcript text to export. If omitted, uses the most recent recording transcript."
            ]
        ],
        "required": ["action"]
    ]

    weak var exportService: MedicalExportService?
    weak var videoRecorder: VideoRecordingService?

    init(exportService: MedicalExportService, videoRecorder: VideoRecordingService?) {
        self.exportService = exportService
        self.videoRecorder = videoRecorder
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "Please specify an action: export_fhir, export_file, share, or status."
        }
        guard let service = exportService else {
            return "Medical export service not available."
        }

        // Get transcript — from args or from the most recent recording
        let transcript: String
        if let provided = args["transcript"] as? String, !provided.isEmpty {
            transcript = provided
        } else if let recorder = videoRecorder {
            let recorderTranscript = await MainActor.run { recorder.recordingTranscript }
            if recorderTranscript.isEmpty {
                return "No transcript available. Start a recording with transcription enabled first, or provide the transcript text."
            }
            transcript = recorderTranscript
        } else {
            return "No transcript available and no recording service connected."
        }

        let now = Date()
        let duration = await MainActor.run { videoRecorder?.formattedDuration ?? "Unknown" }

        switch action {
        case "export_fhir":
            let config = FHIRConfig.fromDefaults()
            guard !config.baseURL.isEmpty else {
                return "FHIR server not configured. Go to Settings → Medical Compliance → Medical Export to configure your FHIR endpoint."
            }

            let result = await service.exportToFHIR(
                transcript: transcript, duration: duration, date: now, config: config
            )
            await MainActor.run { service.lastExportResult = result }

            if result.success {
                return "Transcript uploaded to FHIR server successfully. \(result.message)"
            } else {
                return "FHIR export failed: \(result.message). You can try again or use the share sheet instead."
            }

        case "export_file":
            let formatStr = args["format"] as? String ?? "text"
            let format: ExportFormat
            switch formatStr {
            case "pdf": format = .pdf
            case "fhir_json": format = .fhirJson
            case "hl7": format = .hl7
            default: format = .plainText
            }

            let url = service.createExportFile(
                transcript: transcript, duration: duration, date: now, format: format
            )

            if let url {
                return "Export file created: \(url.lastPathComponent) (\(format.rawValue)). The file is ready for sharing via the Files app or share sheet."
            } else {
                return "Failed to create export file. Try plain text format as a fallback."
            }

        case "share":
            let formatStr = args["format"] as? String ?? "text"
            let format: ExportFormat
            switch formatStr {
            case "pdf": format = .pdf
            case "fhir_json": format = .fhirJson
            case "hl7": format = .hl7
            default: format = .plainText
            }

            let url = service.createExportFile(
                transcript: transcript, duration: duration, date: now, format: format
            )

            if let url {
                // Request share sheet via AppState
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .medicalExportShareRequest,
                        object: nil,
                        userInfo: ["url": url]
                    )
                }
                return "Share sheet opening with the transcript file (\(format.rawValue)). Choose your preferred sharing method."
            } else {
                return "Failed to create export file for sharing."
            }

        case "status":
            let config = FHIRConfig.fromDefaults()
            var lines: [String] = []

            if config.baseURL.isEmpty {
                lines.append("FHIR server: Not configured")
            } else {
                lines.append("FHIR server: \(config.baseURL)")
                if !config.patientId.isEmpty {
                    lines.append("Patient ID: \(config.patientId)")
                }
                if !config.practitionerId.isEmpty {
                    lines.append("Practitioner ID: \(config.practitionerId)")
                }
            }

            let platform = MedicalPlatform(rawValue: config.platformType) ?? .manual
            lines.append("Platform: \(platform.rawValue)")
            lines.append("Auto-export: \(Config.autoExportEnabled ? "Enabled" : "Disabled")")
            lines.append("Default format: \(Config.defaultExportFormat.rawValue)")

            return lines.joined(separator: "\n")

        default:
            return "Unknown action '\(action)'. Use export_fhir, export_file, share, or status."
        }
    }
}

extension Notification.Name {
    static let medicalExportShareRequest = Notification.Name("medicalExportShareRequest")
}
