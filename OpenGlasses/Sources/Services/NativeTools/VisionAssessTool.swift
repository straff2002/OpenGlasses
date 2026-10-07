import Foundation

/// `vision_assess` — run a structured visual assessment of what the glasses camera sees and surface a
/// typed result card (structured-vision plan, Phase 3). Schema-parameterized via `kind`; the built-in
/// `instrument_reading` reads numbers off gauges/thermometers/scales/meters. Delegates to
/// `StructuredVisionService.shared`, which publishes the card and mirrors a summary to the HUD; this
/// tool returns a concise text summary for the LLM to speak.
@MainActor
final class VisionAssessTool: NativeTool {
    let name = "vision_assess"

    var description: String {
        let list = availableList
        return """
        Run a structured visual assessment of what the camera (the glasses when connected, otherwise the phone) sees and show a result card. \
        `kind` selects the assessment type (available: \(list)). Use 'instrument_reading' to read a \
        number off a gauge, thermometer, refractometer, scale, or meter. Optional `note` adds context.
        """
    }

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "description": "Assessment type, e.g. instrument_reading"],
            "note": ["type": "string", "description": "Optional extra context for the assessment"]
        ],
        "required": ["kind"]
    ]

    /// Runs the assessment once the arguments are accepted. The live service by default; a test
    /// injects one to show a call reached it without a camera or a model.
    private let assess: @MainActor (_ kind: String, _ note: String?) async throws -> AssessmentCard
    /// Whether this phone is a work tool, read on every call. The live facts by default; a test
    /// injects them.
    private let editionFacts: @MainActor () -> EditionFacts

    init(assess: (@MainActor (_ kind: String, _ note: String?) async throws -> AssessmentCard)? = nil,
         editionFacts: (@MainActor () -> EditionFacts)? = nil) {
        self.assess = assess ?? { kind, note in
            try await StructuredVisionService.shared.assessCurrentFrame(kind: kind, note: note)
        }
        self.editionFacts = editionFacts ?? { EditionFacts.current() }
    }

    /// Assessment kinds that belong to a switchable AI feature, and the feature whose switch gates
    /// them. Camera triage is part of first-aid assist (Plan HP P1 item 4): turning that feature off
    /// must stop the triage card as well as the coaching, or the inventory's claim is untrue.
    static let gatedKinds: [String: AIFeature] = ["first_aid_triage": .firstAidAssist]

    // MARK: - Personal-use-only kinds (Plan HS P1 item 3)

    /// Whether the app is being used as a work tool on this phone. Plain values, like
    /// `AssistiveModePolicy.Facts`, so both states are tested without a profile or an entitlement.
    struct EditionFacts: Equatable {
        /// A Field Assist edition is active (`Config.fieldAssistEnabled`).
        var fieldAssistEditionActive: Bool
        /// An organisation profile is in force (`PolicyEnvelope.isManaged`).
        var organisationManaged: Bool

        var isWorkTool: Bool { fieldAssistEditionActive || organisationManaged }

        static func current() -> EditionFacts {
            EditionFacts(fieldAssistEditionActive: Config.fieldAssistEnabled,
                         organisationManaged: PolicyEnvelope.isManaged)
        }
    }

    /// Kinds offered for personal use only. Camera triage is kept for a personal wearer and not
    /// offered in Field Assist editions or on a managed phone (owner decision 4, 2026-10-07): a
    /// first-response aid sold to employers is the professional triage use Annex III 5(d) reaches.
    /// First-aid coaching (`first_aid`) is a different tool and is unaffected. The schema stays
    /// registered; the restriction lives here.
    static let personalOnlyKinds: Set<String> = ["first_aid_triage"]

    /// What the wearer hears when a personal-only kind is asked for on a work phone.
    static var personalOnlyRefusal: String {
        String(localized: "Camera triage isn't available in Field Assist editions; first-aid coaching still is.")
    }

    /// The kinds this phone offers now: the registry's, less the personal-only ones on a work phone.
    private var offeredKinds: [String] {
        let all = AssessmentSchemaRegistry.shared.kinds
        guard editionFacts().isWorkTool else { return all }
        return all.filter { !Self.personalOnlyKinds.contains($0) }
    }

    /// The kinds as the description and the guidance messages list them.
    private var availableList: String {
        let offered = offeredKinds
        return offered.isEmpty ? "instrument_reading" : offered.joined(separator: ", ")
    }

    func execute(args: [String: Any]) async throws -> String {
        let kind = (args["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let availableList = self.availableList

        guard !kind.isEmpty else {
            return "Specify what to assess via `kind`. Available: \(availableList)."
        }
        // Before the feature switch: on a work phone, turning first aid on would not help, so the
        // switch is not the reason to give.
        if Self.personalOnlyKinds.contains(kind), editionFacts().isWorkTool {
            return Self.personalOnlyRefusal
        }
        if let feature = Self.gatedKinds[kind], !AIFeatureGate.isEnabled(feature) {
            return AIFeatureGate.disabledMessage(feature)
        }
        guard AssessmentSchemaRegistry.shared.contains(kind) else {
            return "Unknown assessment kind '\(kind)'. Available: \(availableList)."
        }

        let rawNote = (args["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (rawNote?.isEmpty == false) ? rawNote : nil

        do {
            let card = try await assess(kind, note)
            var response = Self.summarize(card)
            // Plan AD × U: if a capture flow is waiting on a voice_number step, the reading fills it
            // (converted to the step's unit, range-validated) instead of dictation, and advances.
            if kind == "instrument_reading", let reading = card.readings.first,
               let flowMessage = CaptureFlowService.shared.fillCurrentStep(with: reading) {
                response += "\n\n\(flowMessage)"
            }
            return response
        } catch StructuredVisionError.noFrame {
            return "I couldn't get a picture from the camera. Make sure the subject is in view and try again."
        } catch StructuredVisionError.analysisFailed {
            return "The visual assessment didn't return a usable result. Try again with a clearer, steadier view."
        } catch {
            return "Vision assessment failed: \(error.localizedDescription)"
        }
    }

    /// A concise, speakable summary of the card for the LLM to relay.
    static func summarize(_ card: AssessmentCard) -> String {
        var lines: [String] = [card.summary]
        for r in card.readings {
            var line = "\(r.quantity): \(fmt(r.value)) \(r.unit)"
            if let c = r.canonical, let cu = r.canonicalUnit, cu != r.unit {
                line += " (\(fmt(c)) \(cu))"
            }
            lines.append(line)
        }
        for f in card.findings {
            lines.append("\(f.severity.displayLabel): \(f.label)")
        }
        if let action = card.recommendedAction, !action.isEmpty {
            lines.append("Recommended: \(action)")
        }
        if !card.stillNeeded.isEmpty {
            lines.append("Still needed: " + card.stillNeeded.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
