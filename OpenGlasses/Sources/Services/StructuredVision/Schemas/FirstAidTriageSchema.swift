import Foundation

/// First-aid casualty-triage schema (structured-vision plan, first-aid consumer): a bystander points
/// the glasses at a casualty and gets a structured, **advisory** triage — responsiveness, breathing,
/// severe bleeding, likely conditions, and a recommended action — with a **deterministic safety
/// backstop** that forces a critical/"call emergency services" result whenever a life-threat sign is
/// present, regardless of what the model rated. Advisory only — not a medical device.
struct FirstAidTriageSchema: AssessmentSchema {
    let kind = "first_aid_triage"
    let title = "First-Aid Triage"
    var confidenceFloor: Double { 0.4 }

    static let disclaimer = "Advisory only — not a medical device. In a real emergency, call your local emergency number immediately."

    var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "responsiveness": ["type": "string", "enum": ["responsive", "unresponsive", "unsure"]],
                "breathing": ["type": "string", "enum": ["yes", "no", "unsure"]],
                "severe_bleeding": ["type": "boolean"],
                "suspected_conditions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "severity": ["type": "string", "enum": ["minor", "major", "critical"]],
                            "confidence": ["type": "number"]
                        ],
                        "required": ["name", "severity"]
                    ]
                ],
                "recommended_action": [
                    "type": "string",
                    "enum": ["call_emergency", "start_cpr", "recovery_position", "control_bleeding", "monitor"]
                ],
                "still_to_check": ["type": "array", "items": ["type": "string"]],
                "summary": ["type": "string"],
                "confidence": ["type": "number"]
            ],
            "required": ["responsiveness", "breathing", "severe_bleeding", "summary"]
        ]
    }

    var systemPrompt: String {
        """
        You are a first-aid TRIAGE assistant for smart glasses, helping a bystander assess a casualty \
        from the camera view. You are ADVISORY ONLY and NOT a medical device — never diagnose. Your \
        priority is to get the right help fast.

        Assess what you can see (plus any context given): is the person responsive, are they breathing, \
        is there severe bleeding, and what conditions are likely. Be conservative — if you are unsure \
        about breathing or responsiveness, answer "unsure", and if anything suggests a life threat, \
        recommend calling emergency services.

        \(AssessmentPrompt.instrumentFragment)

        Return ONLY the structured assessment: responsiveness (responsive | unresponsive | unsure), \
        breathing (yes | no | unsure), severe_bleeding (boolean), suspected_conditions (each with name, \
        severity minor|major|critical, confidence 0.0–1.0), recommended_action (call_emergency | \
        start_cpr | recovery_position | control_bleeding | monitor), still_to_check (what the bystander \
        should check next), a one-sentence summary, and overall confidence 0.0–1.0.
        """
    }

    // MARK: - Adapter

    private struct Payload: Decodable {
        struct Condition: Decodable {
            let name: String
            let severity: String?
            let confidence: Double?
        }
        let responsiveness: String?
        let breathing: String?
        let severeBleeding: Bool?
        let suspectedConditions: [Condition]?
        let recommendedAction: String?
        let stillToCheck: [String]?
        let summary: String?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case responsiveness, breathing
            case severeBleeding = "severe_bleeding"
            case suspectedConditions = "suspected_conditions"
            case recommendedAction = "recommended_action"
            case stillToCheck = "still_to_check"
            case summary, confidence
        }
    }

    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard {
        let p: Payload
        do { p = try AssessmentJSON.decode(Payload.self, from: json) }
        catch { throw AssessmentSchemaError.malformedPayload("\(error)") }

        // Findings: model-reported conditions, plus deterministic findings for the hard life-threat
        // signs so the backstop (which sees only the card) can enforce escalation.
        var findings: [AssessmentFinding] = (p.suspectedConditions ?? []).map {
            AssessmentFinding(label: $0.name, severity: Self.tier(for: $0.severity),
                              confidence: $0.confidence ?? 0.7)
        }
        if p.breathing?.lowercased() == "no" {
            findings.append(AssessmentFinding(label: "Not breathing", severity: .critical))
        }
        if p.responsiveness?.lowercased() == "unresponsive" {
            findings.append(AssessmentFinding(label: "Unresponsive", severity: .critical))
        }
        if p.severeBleeding == true {
            findings.append(AssessmentFinding(label: "Severe bleeding", severity: .critical))
        }

        // Triage is inherently at least caution; raise to the worst finding.
        let tier = findings.reduce(AssessmentTier.caution) { AssessmentTier.escalated($0, $1.severity) }

        let summary = (p.summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Casualty assessed — see findings."

        let card = AssessmentCard(
            kind: kind, title: title, tier: tier, summary: summary,
            findings: findings,
            recommendedAction: Self.action(for: p.recommendedAction),
            stillNeeded: p.stillToCheck ?? [],
            confidence: p.confidence ?? 0.5,
            disclaimer: Self.disclaimer)
        return card
    }

    /// Deterministic safety guardrail: any critical sign forces a critical, call-emergency result —
    /// overriding the model's recommendation if it under-rated the situation.
    func backstop(_ card: AssessmentCard) -> AssessmentCard {
        guard card.findings.contains(where: { $0.severity == .critical }) else { return card }
        let notBreathing = card.findings.contains { $0.label.localizedCaseInsensitiveContains("not breathing") }
        let action = notBreathing
            ? "Call emergency services now (111 / 112 / 911) and begin CPR — chest compressions, 100–120 per minute."
            : "Call emergency services now (111 / 112 / 911)."
        return card.escalating(to: .critical, action: action,
                               appending: "Confirm emergency services have been called.")
    }

    // MARK: - Mapping

    private static func tier(for severity: String?) -> AssessmentTier {
        switch (severity ?? "").lowercased() {
        case "critical": return .critical
        case "major": return .caution
        case "minor": return .ok
        default: return .caution
        }
    }

    private static func action(for action: String?) -> String? {
        switch (action ?? "").lowercased() {
        case "call_emergency": return "Call emergency services now (111 / 112 / 911)."
        case "start_cpr": return "Begin CPR now — chest compressions. Say \"first aid, start CPR\" to be paced."
        case "recovery_position": return "Place them in the recovery position and keep monitoring breathing."
        case "control_bleeding": return "Apply firm, direct pressure to the wound to control the bleeding."
        case "monitor": return "Stay with them and monitor closely; be ready to call for help."
        default: return nil
        }
    }
}
