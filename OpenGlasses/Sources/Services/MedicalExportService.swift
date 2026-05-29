import Foundation
import UIKit

/// Manages export of clinical recordings and transcripts to medical platforms.
///
/// Supports three tiers of integration:
/// 1. **FHIR R4** — universal standard (Epic, Cerner, MEDITECH, Allscripts, etc.)
/// 2. **Platform-specific** — My Health Record (AU), GP2GP (NZ), NHS Spine (UK)
/// 3. **Manual** — share sheet, AirDrop, Files, email
///
/// All exports are logged in the HIPAA audit trail when Medical Compliance mode is active.
@MainActor
class MedicalExportService: ObservableObject {
    @Published var isExporting = false
    @Published var lastExportResult: ExportResult?

    weak var hipaaService: HIPAAComplianceService?

    struct ExportResult: Identifiable {
        let id = UUID()
        let success: Bool
        let platform: MedicalPlatform
        let message: String
        let timestamp: Date
    }

    // MARK: - Export to FHIR

    /// Export a transcript as a FHIR R4 DocumentReference resource.
    /// Posts to the configured FHIR server endpoint.
    func exportToFHIR(transcript: String, duration: String, date: Date,
                      config: FHIRConfig) async -> ExportResult {
        isExporting = true
        defer { isExporting = false }

        let resource = buildFHIRDocumentReference(
            transcript: transcript, duration: duration, date: date, config: config
        )

        guard let url = URL(string: "\(config.baseURL)/DocumentReference") else {
            return ExportResult(success: false, platform: .fhir,
                                message: "Invalid FHIR server URL", timestamp: Date())
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/fhir+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/fhir+json", forHTTPHeaderField: "Accept")

        // Auth: Bearer token or Basic auth
        if !config.bearerToken.isEmpty {
            request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        } else if !config.clientId.isEmpty {
            // SMART on FHIR OAuth flow would go here — for now, support pre-obtained tokens
            NSLog("[MedicalExport] SMART on FHIR OAuth not yet implemented — use bearer token")
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: resource)
            request.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            if (200...299).contains(statusCode) {
                let result = ExportResult(success: true, platform: .fhir,
                                          message: "Document uploaded to FHIR server (HTTP \(statusCode))",
                                          timestamp: Date())
                hipaaService?.log(action: "FHIR_EXPORT", detail: "Transcript exported to \(config.baseURL)")
                return result
            } else {
                return ExportResult(success: false, platform: .fhir,
                                    message: "FHIR server returned HTTP \(statusCode)",
                                    timestamp: Date())
            }
        } catch {
            return ExportResult(success: false, platform: .fhir,
                                message: "Export failed: \(error.localizedDescription)",
                                timestamp: Date())
        }
    }

    /// Build a FHIR R4 DocumentReference resource from a transcript.
    private func buildFHIRDocumentReference(transcript: String, duration: String,
                                             date: Date, config: FHIRConfig) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        let dateString = isoFormatter.string(from: date)
        let base64Content = Data(transcript.utf8).base64EncodedString()

        var resource: [String: Any] = [
            "resourceType": "DocumentReference",
            "status": "current",
            "type": [
                "coding": [[
                    "system": "http://loinc.org",
                    "code": "11506-3",
                    "display": "Progress note"
                ]]
            ],
            "category": [[
                "coding": [[
                    "system": "http://loinc.org",
                    "code": "11506-3",
                    "display": "Clinical note"
                ]]
            ]],
            "date": dateString,
            "description": "Clinical recording transcript (\(duration))",
            "content": [[
                "attachment": [
                    "contentType": "text/plain",
                    "data": base64Content,
                    "title": "Recording Transcript \(dateString)",
                    "creation": dateString
                ]
            ]]
        ]

        // Add patient reference if configured
        if !config.patientId.isEmpty {
            resource["subject"] = ["reference": "Patient/\(config.patientId)"]
        }

        // Add practitioner reference if configured
        if !config.practitionerId.isEmpty {
            resource["author"] = [["reference": "Practitioner/\(config.practitionerId)"]]
        }

        return resource
    }

    // MARK: - Export File for Manual Sharing

    /// Create an export file bundle (transcript + metadata) ready for sharing.
    /// Returns a URL to the export file that can be passed to the share sheet.
    func createExportFile(transcript: String, duration: String, date: Date,
                          format: ExportFormat = .plainText) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let dateString = dateFormatter.string(from: date)

        switch format {
        case .plainText:
            let fileName = "clinical_transcript_\(dateString).txt"
            let url = tempDir.appendingPathComponent(fileName)
            try? transcript.write(to: url, atomically: true, encoding: .utf8)
            hipaaService?.log(action: "EXPORT_FILE_CREATED", detail: fileName)
            return url

        case .pdf:
            let fileName = "clinical_transcript_\(dateString).pdf"
            let url = tempDir.appendingPathComponent(fileName)
            if createPDF(transcript: transcript, duration: duration, date: date, outputURL: url) {
                hipaaService?.log(action: "EXPORT_FILE_CREATED", detail: fileName)
                return url
            }
            return nil

        case .fhirJson:
            let fileName = "clinical_document_\(dateString).fhir.json"
            let url = tempDir.appendingPathComponent(fileName)
            let config = FHIRConfig.fromDefaults()
            let resource = buildFHIRDocumentReference(
                transcript: transcript, duration: duration, date: date, config: config
            )
            if let data = try? JSONSerialization.data(withJSONObject: resource, options: .prettyPrinted) {
                try? data.write(to: url)
                hipaaService?.log(action: "EXPORT_FILE_CREATED", detail: fileName)
                return url
            }
            return nil

        case .hl7:
            let fileName = "clinical_message_\(dateString).hl7"
            let url = tempDir.appendingPathComponent(fileName)
            let hl7Message = buildHL7Message(transcript: transcript, duration: duration, date: date)
            try? hl7Message.write(to: url, atomically: true, encoding: .utf8)
            hipaaService?.log(action: "EXPORT_FILE_CREATED", detail: fileName)
            return url
        }
    }

    // MARK: - PDF Generation

    private func createPDF(transcript: String, duration: String, date: Date, outputURL: URL) -> Bool {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 50

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        do {
            try renderer.writePDF(to: outputURL) { context in
                context.beginPage()

                // Header
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: UIColor.black
                ]
                let header = "Clinical Recording Transcript"
                header.draw(at: CGPoint(x: margin, y: margin), withAttributes: headerAttrs)

                // Metadata
                let metaAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.darkGray
                ]
                let meta = "Date: \(dateFormatter.string(from: date))\nDuration: \(duration)\nSource: OpenGlasses Smart Glasses"
                meta.draw(at: CGPoint(x: margin, y: margin + 24), withAttributes: metaAttrs)

                // Separator
                let separatorY = margin + 70
                context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                context.cgContext.move(to: CGPoint(x: margin, y: separatorY))
                context.cgContext.addLine(to: CGPoint(x: pageRect.width - margin, y: separatorY))
                context.cgContext.strokePath()

                // Body text
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.black
                ]
                let textRect = CGRect(x: margin, y: separatorY + 10,
                                       width: pageRect.width - margin * 2,
                                       height: pageRect.height - separatorY - margin - 10)
                let attributedText = NSAttributedString(string: transcript, attributes: bodyAttrs)
                attributedText.draw(in: textRect)
            }
            return true
        } catch {
            NSLog("[MedicalExport] PDF creation failed: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - HL7 v2 Message

    /// Build a basic HL7 v2.x MDM (Medical Document Management) message.
    /// Used by older systems that don't support FHIR.
    private func buildHL7Message(transcript: String, duration: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: date)
        let msgId = UUID().uuidString.prefix(20)

        // Escape HL7 special characters. The escape character "\" MUST be escaped first, otherwise
        // it corrupts the backslashes introduced by the field/component escapes below.
        let escapedText = transcript
            .replacingOccurrences(of: "\\", with: "\\E\\")
            .replacingOccurrences(of: "|", with: "\\F\\")
            .replacingOccurrences(of: "^", with: "\\S\\")
            .replacingOccurrences(of: "&", with: "\\T\\")
            .replacingOccurrences(of: "~", with: "\\R\\")
            .replacingOccurrences(of: "\n", with: "\\.br\\")

        return """
        MSH|^~\\&|OpenGlasses|SmartGlasses|EMR|Hospital|\(timestamp)||MDM^T02|MSG\(msgId)|P|2.5.1
        EVN|T02|\(timestamp)
        TXA|1|CN|TX|\(timestamp)|||\(timestamp)||||||||AU
        OBX|1|TX|11506-3^Progress note^LN||Duration: \(duration)\\.br\\\(escapedText)||||||F
        """
    }
}

// MARK: - Supporting Types

/// Supported medical platform types.
enum MedicalPlatform: String, CaseIterable, Identifiable {
    case fhir = "FHIR R4"
    case epic = "Epic MyChart"
    case cerner = "Oracle Health (Cerner)"
    case myHealthRecord = "My Health Record (AU)"
    case nzHealthConnect = "NZ Health Connect"
    case nhsSpine = "NHS Spine (UK)"
    case manual = "Manual Share"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fhir: return "server.rack"
        case .epic: return "building.2.fill"
        case .cerner: return "building.2.fill"
        case .myHealthRecord: return "cross.case.fill"
        case .nzHealthConnect: return "cross.case.fill"
        case .nhsSpine: return "cross.case.fill"
        case .manual: return "square.and.arrow.up"
        }
    }

    var flag: String {
        switch self {
        case .fhir: return "🌐"
        case .epic, .cerner: return "🇺🇸"
        case .myHealthRecord: return "🇦🇺"
        case .nzHealthConnect: return "🇳🇿"
        case .nhsSpine: return "🇬🇧"
        case .manual: return "📤"
        }
    }

    var description: String {
        switch self {
        case .fhir:
            return "Universal healthcare API standard. Compatible with Epic, Cerner, MEDITECH, Allscripts, and most modern EMRs."
        case .epic:
            return "Epic MyChart patient portal and EHR. Uses FHIR R4 with SMART on FHIR authentication."
        case .cerner:
            return "Oracle Health (formerly Cerner). Uses FHIR R4 with Millennium platform integration."
        case .myHealthRecord:
            return "Australian national health record system operated by the Australian Digital Health Agency."
        case .nzHealthConnect:
            return "New Zealand Health Information Platform for sharing between primary and secondary care."
        case .nhsSpine:
            return "NHS national IT infrastructure for healthcare messaging and record access."
        case .manual:
            return "Share via AirDrop, email, Files app, or any other sharing method on your device."
        }
    }

    /// Whether this platform uses FHIR under the hood.
    var usesFHIR: Bool {
        switch self {
        case .fhir, .epic, .cerner: return true
        default: return false
        }
    }
}

/// Export file format options.
enum ExportFormat: String, CaseIterable, Identifiable {
    case plainText = "Plain Text (.txt)"
    case pdf = "PDF Document (.pdf)"
    case fhirJson = "FHIR Resource (.json)"
    case hl7 = "HL7 Message (.hl7)"

    var id: String { rawValue }
}

/// FHIR server configuration.
struct FHIRConfig: Codable {
    var baseURL: String = ""
    var bearerToken: String = ""
    var clientId: String = ""       // For SMART on FHIR OAuth
    var clientSecret: String = ""
    var patientId: String = ""
    var practitionerId: String = ""
    var platformType: String = "fhir" // fhir, epic, cerner

    /// Load from UserDefaults.
    static func fromDefaults() -> FHIRConfig {
        guard let data = UserDefaults.standard.data(forKey: "fhirConfig"),
              let config = try? JSONDecoder().decode(FHIRConfig.self, from: data) else {
            return FHIRConfig()
        }
        return config
    }

    /// Save to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "fhirConfig")
        }
    }
}
