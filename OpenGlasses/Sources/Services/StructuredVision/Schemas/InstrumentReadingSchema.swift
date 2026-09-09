import Foundation

/// The built-in, domain-free "read the instrument" schema (structured-vision plan, Phase 3): point the
/// glasses at a physical display — thermometer, pressure/manifold gauge, refractometer, scale,
/// multimeter, any meter — and get the number(s) back as typed `InstrumentReading`s, unit-normalized.
/// No vertical required; usable on its own via `vision_assess kind:"instrument_reading"`.
struct InstrumentReadingSchema: AssessmentSchema {
    let kind = "instrument_reading"
    let title = "Instrument Reading"
    var confidenceFloor: Double { 0.5 }

    var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "readings": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "quantity": ["type": "string", "description": "e.g. temperature, pressure, brix, weight, voltage"],
                            "instrument": ["type": "string", "description": "the device, if identifiable"],
                            "value": ["type": "number"],
                            "unit": ["type": "string", "description": "the unit EXACTLY as displayed, e.g. °F, psig, °Bx, lb, V"],
                            "confidence": ["type": "number", "description": "0.0–1.0"],
                            "region": ["type": "array", "items": ["type": "number"], "description": "normalized [x,y,w,h] of the display"]
                        ],
                        "required": ["quantity", "value", "unit", "confidence"]
                    ]
                ],
                "summary": ["type": "string"],
                "confidence": ["type": "number"]
            ],
            "required": ["readings", "summary"]
        ]
    }

    var systemPrompt: String {
        """
        You are an instrument-reading assistant for smart glasses. The user points the camera at a \
        physical display — a thermometer, pressure or manifold gauge, refractometer, scale, multimeter, \
        or any meter — and wants the value(s) read back.

        \(AssessmentPrompt.instrumentFragment)

        Return ONLY the structured assessment: a `readings` array (each with quantity, the instrument if \
        identifiable, value, the unit exactly as displayed, and confidence 0.0–1.0, plus a normalized \
        [x,y,w,h] region for the display when you can), a one-sentence `summary`, and an overall \
        `confidence`. If no instrument or display is visible, return an empty `readings` array and say so \
        in the summary.
        """
    }

    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard {
        let items = json["readings"] as? [[String: Any]] ?? []
        let readings = items.compactMap { try? AssessmentJSON.decode(InstrumentReading.self, from: $0) }

        let rawSummary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = !rawSummary.isEmpty ? rawSummary
            : (readings.isEmpty ? "No instrument display detected — point the camera at the gauge."
                                : "Read \(readings.count) value\(readings.count == 1 ? "" : "s").")

        // The mean is taken over the confidences the model actually reported. If it reported none,
        // the card carries none — an unreported confidence never becomes a number here.
        let reported = readings.compactMap(\.confidence)
        let confidence = (json["confidence"] as? Double)
            ?? (reported.isEmpty ? nil : reported.reduce(0, +) / Double(reported.count))

        let base = AssessmentCard(
            kind: kind, title: title,
            tier: readings.isEmpty ? .caution : .ok,
            summary: summary,
            stillNeeded: readings.isEmpty ? ["Point the camera squarely at the instrument display."] : [],
            readings: readings, confidence: confidence)

        // Normalize units and convert any low-confidence reading into a re-capture prompt.
        return applyingReadingPolicy(to: base)
    }
}
