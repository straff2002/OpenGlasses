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
        let available = AssessmentSchemaRegistry.shared.kinds
        let list = available.isEmpty ? "instrument_reading" : available.joined(separator: ", ")
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

    func execute(args: [String: Any]) async throws -> String {
        let kind = (args["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let available = AssessmentSchemaRegistry.shared.kinds
        let availableList = available.isEmpty ? "instrument_reading" : available.joined(separator: ", ")

        guard !kind.isEmpty else {
            return "Specify what to assess via `kind`. Available: \(availableList)."
        }
        guard AssessmentSchemaRegistry.shared.contains(kind) else {
            return "Unknown assessment kind '\(kind)'. Available: \(availableList)."
        }

        let rawNote = (args["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (rawNote?.isEmpty == false) ? rawNote : nil

        do {
            let card = try await StructuredVisionService.shared.assessCurrentFrame(kind: kind, note: note)
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
