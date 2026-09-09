import Foundation

/// First-aid casualty triage on the structured-vision substrate (structured-vision plan, Phase 3
/// consumer — unblocked once first-aid coaching shipped). Point the glasses at a casualty and get a
/// typed triage: responsiveness, breathing, severe bleeding, and visible injuries → a tiered
/// `AssessmentCard`. The life-safety call (tier + recommended action) is computed **deterministically**
/// from the reported vitals, not left to the model — the same guardrail posture as HECA.
///
/// Advisory only — not a medical diagnosis; always escalates to emergency services. Pairs with the
/// `first_aid` coaching tool (triage tells you *what's wrong*; first_aid walks the *response*).
struct FirstAidTriageSchema: AssessmentSchema {
    let kind = "first_aid_triage"
    let title = "First-Aid Triage"

    static let disclaimer = "Advisory only — not a medical diagnosis. Call emergency services."

    var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "responsive": ["type": "boolean", "description": "Does the casualty appear responsive / conscious?"],
                "breathing": ["type": "string", "enum": ["normal", "abnormal", "absent", "unknown"],
                              "description": "Breathing status, as best visible (chest movement, gasping=abnormal)."],
                "severe_bleeding": ["type": "boolean", "description": "Is there visible severe/arterial bleeding?"],
                "findings": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string", "description": "e.g. 'open fracture, left forearm'"],
                            "detail": ["type": "string"],
                            "severity": ["type": "string", "enum": AssessmentTier.allCases.map(\.rawValue)],
                            "region": ["type": "array", "items": ["type": "number"], "description": "normalized [x,y,w,h]"]
                        ],
                        "required": ["label", "severity"]
                    ]
                ],
                "summary": ["type": "string"],
                "confidence": ["type": "number"]
            ],
            "required": ["responsive", "breathing", "severe_bleeding", "summary"]
        ]
    }

    var systemPrompt: String {
        """
        You are a first-aid triage assistant for smart glasses. The user points the camera at a casualty \
        and needs a fast, factual triage — NOT a diagnosis. Report only what you can actually see.

        Assess three life-safety vitals: is the person `responsive`; is `breathing` normal / abnormal \
        (gasping, irregular) / absent / unknown; and is there `severe_bleeding` (heavy or spurting). Then \
        list visible injuries as `findings`, each with a short label, a `severity` of ok / caution / \
        critical, and a normalized [x,y,w,h] `region` when you can localise it.

        \(AssessmentPrompt.instrumentFragment)

        Do not invent vitals you cannot observe — use "unknown" for breathing, omit `responsive` \
        entirely when you cannot tell, and omit uncertain findings. An unobserved vital is reported \
        as unobserved; the system will say so rather than clear the casualty. \
        Return ONLY the structured assessment (responsive, breathing, severe_bleeding, findings, a \
        one-sentence summary, and overall confidence). The system decides the urgency and the recommended \
        action from these vitals; you just report them accurately.
        """
    }

    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard {
        let responsive = json["responsive"] as? Bool
        let breathing = (json["breathing"] as? String)?.lowercased()
        let severeBleeding = (json["severe_bleeding"] as? Bool) ?? false
        let notBreathing = breathing == "absent"
        let abnormalBreathing = breathing == "abnormal"
        let unresponsive = responsive == false

        let modelFindings = (json["findings"] as? [[String: Any]] ?? [])
            .compactMap { try? AssessmentJSON.decode(AssessmentFinding.self, from: $0) }

        // Deterministic life-safety findings from the reported vitals.
        var findings: [AssessmentFinding] = []
        if notBreathing { findings.append(AssessmentFinding(label: "Not breathing", severity: .critical)) }
        if severeBleeding { findings.append(AssessmentFinding(label: "Severe bleeding", severity: .critical)) }
        if unresponsive && !notBreathing {
            findings.append(AssessmentFinding(label: "Unresponsive (breathing present)", severity: .critical))
        }
        if abnormalBreathing { findings.append(AssessmentFinding(label: "Abnormal breathing", severity: .caution)) }
        findings += modelFindings

        // Whether the model could actually observe the two vitals the triage turns on. A model that
        // reported "unknown" breathing, or no responsiveness at all, has told us it could not see —
        // and a card that answers that with "OK" invents the observation it was denied.
        let vitalsEstablished = responsive != nil && breathing != nil && breathing != "unknown"

        // Recommended action by strict priority: airway/breathing → bleeding → responsiveness.
        let action: String?
        if notBreathing {
            action = "Not breathing — start CPR now and call emergency services."
        } else if severeBleeding {
            action = "Severe bleeding — apply firm direct pressure and call emergency services."
        } else if unresponsive {
            action = "Unresponsive but breathing — place in the recovery position and call emergency services."
        } else if abnormalBreathing {
            action = "Monitor breathing closely and be ready to start CPR. Call emergency services."
        } else if !findings.isEmpty {
            action = "Call emergency services and keep monitoring the casualty."
        } else if !vitalsEstablished {
            action = "Vitals could not be assessed from this view — check responsiveness and breathing yourself, and call emergency services."
        } else {
            action = nil
        }

        var tier = findings.reduce(AssessmentTier.ok) { AssessmentTier.escalated($0, $1.severity) }
        var stillNeeded: [String] = []
        var limitations: [String] = []
        if !vitalsEstablished {
            limitations.append("responsiveness and breathing could not be assessed from this view")
            stillNeeded.append("Check responsiveness and breathing yourself.")
            // Only an unearned all-clear is replaced. A visible injury still ranks the card.
            if tier == .ok { tier = .unknown }
        }

        let rawSummary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = !rawSummary.isEmpty ? rawSummary
            : (findings.isEmpty
                ? (vitalsEstablished ? "No casualty in view — point the camera at the person."
                                     : "Could not assess the casualty from this view.")
                : "Triage: \(findings.count) finding\(findings.count == 1 ? "" : "s").")

        let readings = (json["readings"] as? [[String: Any]] ?? [])
            .compactMap { try? AssessmentJSON.decode(InstrumentReading.self, from: $0) }

        return AssessmentCard(
            kind: kind, title: title, tier: tier, summary: summary,
            findings: findings, recommendedAction: action,
            stillNeeded: stillNeeded,
            readings: readings,
            // The model's own number, or none. `confidence` is optional in this schema and stays
            // optional here: an omitted rating is not a perfect one.
            confidence: json["confidence"] as? Double,
            limitations: limitations,
            disclaimer: Self.disclaimer
        ).normalizingReadings()
    }
}
