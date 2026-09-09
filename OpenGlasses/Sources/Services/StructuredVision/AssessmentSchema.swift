import Foundation

/// The full contract for one structured-vision vertical (see docs/plans/structured-vision-assessment.md):
/// a JSON Schema (the forced tool `input_schema` / Gemini `responseSchema`), a system prompt, and an
/// adapter that maps the decoded payload onto a normalized `AssessmentCard`. Adding a vertical never
/// touches the renderer, the networking, or the tool — only a schema is registered.
///
/// Schemas are PURE (no MainActor, no network): `makeCard` is given an already-decoded JSON object.
protocol AssessmentSchema {
    /// Stable id used by the `vision_assess` tool's `kind` parameter.
    var kind: String { get }
    /// Human title for the card header.
    var title: String { get }
    /// The JSON Schema handed to the provider as a forced tool `input_schema` / `responseSchema`.
    var jsonSchema: [String: Any] { get }
    /// The system prompt for the assessment call. Implementations should include
    /// `AssessmentPrompt.instrumentFragment` so every vertical reads instruments for free.
    var systemPrompt: String { get }
    /// Findings/readings below this confidence are surfaced as a re-capture, not landed silently.
    var confidenceFloor: Double { get }

    /// Map the decoded model JSON onto a normalized card.
    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard

    /// Deterministic guardrail run AFTER the model. May only ESCALATE tier / force an action —
    /// never downgrade. Default is identity.
    func backstop(_ card: AssessmentCard) -> AssessmentCard
}

extension AssessmentSchema {
    var confidenceFloor: Double { 0.4 }
    func backstop(_ card: AssessmentCard) -> AssessmentCard { card }

    /// Convenience: normalize readings, then push any reading below `confidenceFloor` into
    /// `stillNeeded` as a re-capture prompt. Schemas call this from `makeCard` before returning.
    /// A reading whose confidence the model did not report is treated exactly like one it reported
    /// as low: unestablished, so re-capture. The alternative — assuming a missing number meant a
    /// good one — is the fabrication this whole path exists to stop.
    func applyingReadingPolicy(to card: AssessmentCard) -> AssessmentCard {
        let normalized = card.normalizingReadings()
        let unestablished = normalized.readings.filter { ($0.confidence ?? 0) < confidenceFloor }
        guard !unestablished.isEmpty else { return normalized }
        let recaptures = unestablished.map { reading -> String in
            reading.confidence == nil
                ? "Re-capture the \(reading.quantity) display (confidence not reported)."
                : "Re-capture the \(reading.quantity) display (low confidence)."
        }
        return normalized.with(stillNeeded: normalized.stillNeeded + recaptures)
    }
}

/// Reusable system-prompt fragments shared across schemas.
enum AssessmentPrompt {
    /// The standing "say what you could not see" instruction (W08.2). A model that reports a partial
    /// or blocked view lets the app qualify or withhold the result instead of presenting a guess as
    /// an observation, so every vertical asks for it and `InputQualityIndicators` reads it back.
    static let viewLimitationsFragment = """
    VIEW LIMITS: report what you could NOT see. Set `partial_view` true when only part of the \
    subject or scene is in frame, `view_obstructed` true when something blocks your view, and list \
    any further limits in `view_limitations` (short phrases). Never fill a gap in the view with an \
    assumption — an unobserved thing is unobserved, not absent.
    """

    /// JSON-Schema properties backing the fragment above. Optional in every schema: a model that
    /// omits them reports no limitation, which is not the same as reporting a clear view.
    static var viewLimitationsProperties: [String: Any] {
        [
            "partial_view": ["type": "boolean",
                             "description": "True when only part of the subject or scene was visible."],
            "view_obstructed": ["type": "boolean",
                                "description": "True when something blocked the view."],
            "view_limitations": ["type": "array", "items": ["type": "string"],
                                 "description": "Short phrases naming anything else that limited the view."],
        ]
    }

    /// Augmented copies of a schema's prompt + JSON schema carrying the view-limit capability.
    /// Applied at the `StructuredVisionService.assess` chokepoint, the same way privacy reporting is,
    /// so a new vertical gets it without knowing it exists. Non-destructive.
    static func augmentingViewLimits(systemPrompt: String, jsonSchema: [String: Any])
        -> (systemPrompt: String, jsonSchema: [String: Any]) {
        var schema = jsonSchema
        if var properties = schema["properties"] as? [String: Any] {
            for (key, value) in viewLimitationsProperties where properties[key] == nil {
                properties[key] = value
            }
            schema["properties"] = properties
        }
        return (systemPrompt + "\n\n" + viewLimitationsFragment, schema)
    }

    /// The standing "read the instrument" instruction every schema should include, so instrument
    /// reading is picked up for free even by verticals not primarily about measurement.
    static let instrumentFragment = """
    Read any visible instrument, gauge, label, meter, thermometer, refractometer, or scale and report \
    each as a reading with its numeric value, the unit exactly as displayed, and a confidence 0.0–1.0. \
    Never guess an off-screen, blurry, or illegible value — lower the confidence instead of inventing a number.
    """
}

/// Errors a schema may throw while mapping model output.
enum AssessmentSchemaError: Error, LocalizedError {
    case unknownKind(String)
    case malformedPayload(String)

    var errorDescription: String? {
        switch self {
        case .unknownKind(let k): return "No assessment schema registered for kind '\(k)'."
        case .malformedPayload(let m): return "Assessment payload could not be mapped: \(m)"
        }
    }
}
