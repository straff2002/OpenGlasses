import Foundation

/// Pure assembly + validation of a `CaptureFlow` from no-code author input (Plan U
/// follow-up). The `CaptureFlowAuthorView` collects step drafts; this turns them into
/// a validated `CaptureFlow` and the JSON the library loads — so authored flows round-trip
/// through `CaptureFlowLibrary.decode`. Headless-testable; the SwiftUI form is the thin edge.
enum CaptureFlowBuilder {

    /// One step as entered in the author UI (strings the form binds to).
    struct StepDraft: Equatable, Identifiable {
        let id = UUID()
        var field: String = ""
        var prompt: String = ""
        var type: BindingType = .voice
        var unit: String = ""              // voice_number
        var optionsCSV: String = ""        // enum, comma-separated
        var required: Bool = true
    }

    enum BuildError: LocalizedError, Equatable {
        case emptyId, emptyTitle, noSteps
        case invalidField(String)
        case duplicateField(String)
        case enumWithoutOptions(String)

        var errorDescription: String? {
            switch self {
            case .emptyId: return String(localized: "Give the flow an id.")
            case .emptyTitle: return String(localized: "Give the flow a title.")
            case .noSteps: return String(localized: "Add at least one step.")
            case .invalidField(let f): return String(localized: "Step field \"\(f)\" must be lowercase letters, numbers, or underscores.")
            case .duplicateField(let f): return String(localized: "Duplicate step field \"\(f)\".")
            case .enumWithoutOptions(let f): return String(localized: "The choice step \"\(f)\" needs at least two options.")
            }
        }
    }

    /// Validate + assemble. Field names must be slugs and unique; enum steps need ≥2 options.
    static func build(id: String, title: String, steps: [StepDraft]) -> Result<CaptureFlow, BuildError> {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .failure(.emptyId) }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.emptyTitle) }
        guard !steps.isEmpty else { return .failure(.noSteps) }

        var seen = Set<String>()
        var built: [FlowStep] = []
        for draft in steps {
            let field = draft.field.trimmingCharacters(in: .whitespaces)
            guard isSlug(field) else { return .failure(.invalidField(field)) }
            guard seen.insert(field).inserted else { return .failure(.duplicateField(field)) }

            let options = draft.optionsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if draft.type == .enumChoice, options.count < 2 { return .failure(.enumWithoutOptions(field)) }

            let unit = draft.unit.trimmingCharacters(in: .whitespaces)
            let binding = FieldBinding(type: draft.type,
                                       unit: (draft.type == .voiceNumber && !unit.isEmpty) ? unit : nil,
                                       options: draft.type == .enumChoice ? options : nil)
            built.append(FlowStep(field: field,
                                  prompt: draft.prompt.trimmingCharacters(in: .whitespaces),
                                  binding: binding,
                                  required: draft.required))
        }
        return .success(CaptureFlow(id: id, title: title.trimmingCharacters(in: .whitespaces), steps: built))
    }

    /// Pretty JSON for export / saving as an overlay flow.
    static func encode(_ flow: CaptureFlow) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(flow)
    }

    /// `^[a-z][a-z0-9_]*$` — a vault field slug.
    static func isSlug(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter, first.isLowercase else { return false }
        return s.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" }
    }
}
