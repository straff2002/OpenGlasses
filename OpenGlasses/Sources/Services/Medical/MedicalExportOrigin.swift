import Foundation

/// Who wrote the text a clinical export carries (Plan HQ P1 item 2).
///
/// The same export path carries two very different things: the recorder's raw speech-to-text of
/// what was said in the room, and text a model wrote and handed to the `medical_export` tool. A
/// reader of the record — a clinician, an EMR, an auditor — needs to know which. The service cannot
/// tell from the string, so **the caller decides**: it knows where it got the text. There is no
/// default and no inference.
///
/// Every format states it, in the shape that format has for a note: a printed line and the PDF's
/// metadata, a `meta.tag` and the `description` on the FHIR resource (file and network alike), an
/// `NTE` segment in HL7, and the first line of the plain-text file. Provenance never carries health
/// content — only the origin, the model, a digest of its instruction version, the time and the
/// app build.
///
/// "Automatic transcription" is not a claim of AI-generated content: it is the speaker's own words
/// as the recogniser heard them, and the line says exactly that.
enum MedicalExportOrigin: Equatable {
    /// The recorder's speech-to-text of the recording, unaltered.
    case automaticTranscription
    /// Text a model wrote. `nil` when no model was recorded — still model-written, and said so.
    case modelAuthored(AIProvenance?)

    /// The FHIR `meta.tag` system for the origin and model tags.
    static let fhirTagSystem = "urn:avenkin:provenance"
    /// The FHIR `meta.tag` system whose code is the model identifier.
    static let fhirModelTagSystem = "urn:avenkin:provenance:model"

    static let automaticTranscriptionCode = "automatic-transcription"
    static let aiGeneratedCode = "ai-generated"
    static let unrecordedModelCode = "unrecorded"

    /// The provenance for text the model handed to the export tool: the active model, under the
    /// conversation's instruction identity. `nil` when no model is configured.
    static func modelAuthoredByActiveModel(generatedAt: Date = Date()) -> MedicalExportOrigin {
        .modelAuthored(AIProvenance.forActiveModel(
            promptSources: [AgentArchiveProvenance.promptIdentity], generatedAt: generatedAt))
    }

    /// The one sentence every format carries.
    var statement: String {
        switch self {
        case .automaticTranscription:
            return "Automatic speech-to-text transcription of the recording, made by Avenkin "
                + "\(AIProvenance.currentAppVersion). Not AI-generated text."
        case .modelAuthored(let provenance?):
            return provenance.footerLine
        case .modelAuthored(nil):
            return "AI-generated text. The model was not recorded."
        }
    }

    /// The FHIR `meta.tag` codings: the origin, and for model text the model.
    var fhirTags: [[String: String]] {
        switch self {
        case .automaticTranscription:
            return [["system": Self.fhirTagSystem, "code": Self.automaticTranscriptionCode,
                     "display": "Automatic speech-to-text transcription"]]
        case .modelAuthored(let provenance):
            return [
                ["system": Self.fhirTagSystem, "code": Self.aiGeneratedCode, "display": "AI-generated text"],
                ["system": Self.fhirModelTagSystem,
                 "code": provenance?.modelIdentifier ?? Self.unrecordedModelCode,
                 "display": "Model that wrote the text"],
            ]
        }
    }

    /// The PDF stamp: trained-algorithmic for model text; composite for a transcription, which is
    /// human speech passed through a recogniser.
    func pdfStamp(title: String, date: Date) -> PDFProvenanceStamp {
        switch self {
        case .automaticTranscription:
            let version = AIProvenance.currentAppVersion
            return PDFProvenanceStamp(
                title: title,
                creator: "Avenkin \(version) — automatic transcription",
                subject: statement,
                keywords: ["Automatic transcription"],
                sourceType: .compositeWithTrainedAlgorithmicMedia,
                creatorTool: "Avenkin \(version)",
                createdAt: date)
        case .modelAuthored(let provenance):
            return PDFProvenanceStamp.aiGenerated(
                provenance: provenance, title: title, composite: false,
                unrecordedSubject: statement, now: date)
        }
    }
}
