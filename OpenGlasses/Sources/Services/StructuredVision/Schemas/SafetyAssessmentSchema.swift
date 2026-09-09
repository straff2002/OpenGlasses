import Foundation

/// HECA (High-Energy Control Assessment) schema on the structured-vision substrate
/// (docs/plans/safety-assessment.md). Provides the certified-safety-expert prompt + the enum-constrained
/// structured-output schema, decodes the rich `SafetyReport` (all 13 hazards + score), and maps it onto
/// the generic `AssessmentCard` for the card/HUD. Advisory only — not a certified inspection.
struct SafetyAssessmentSchema: AssessmentSchema {
    let kind = "safety_assessment"
    let title = "Safety Assessment"

    static let disclaimer = "Advisory only — verify on site. Not a certified safety inspection."

    var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "assessments": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "category": ["type": "string", "enum": HighEnergyHazard.allCases.map(\.rawValue)],
                            "is_present": ["type": "boolean"],
                            "has_direct_control": ["type": "boolean"],
                            "direct_control": ["type": "string"],
                            "has_indirect_control": ["type": "boolean"],
                            "indirect_control": ["type": "string"],
                            "comments": ["type": "string"],
                            "evidence": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "note": ["type": "string"],
                                        "box_2d": ["type": "array", "items": ["type": "integer"],
                                                   "description": "[ymin, xmin, ymax, xmax] normalized 0–1000"]
                                    ],
                                    "required": ["note", "box_2d"]
                                ]
                            ]
                        ],
                        "required": ["category", "is_present", "has_direct_control", "has_indirect_control", "comments"]
                    ]
                ]
            ],
            "required": ["summary", "assessments"]
        ]
    }

    var systemPrompt: String {
        let catalog = HighEnergyHazard.allCases
            .map { "  - \($0.rawValue): \($0.displayName) — \($0.energyThreshold)" }
            .joined(separator: "\n")
        return """
        You are a certified occupational-safety expert running a High-Energy Control Assessment (HECA) per \
        the EEI / CSRA "Power to Prevent SIF" methodology on a single job-site image. For EACH of the 13 \
        high-energy hazard categories below, decide whether it is present in the scene and whether it is \
        safeguarded by a control.

        Apply the rigorous 3-part DIRECT-control test — a control is DIRECT only if it (1) is specifically \
        targeted to that high-energy hazard, (2) drops the energy below the SIF threshold when properly \
        installed/verified/used, and (3) stays effective even if a worker makes an unintentional mistake \
        (e.g. fall arrest, fixed machine guarding, de-energization + lockout/tagout, trench shields, \
        arc-rated suits). Everything else — training, signage, PPE, spotters, awareness — is INDIRECT.

        The 13 categories (use these exact ids):
        \(catalog)

        For every present hazard, localise specific unsafe conditions with an evidence note and a \
        box_2d = [ymin, xmin, ymax, xmax] normalized 0–1000. If the image is not a job-site scene, mark \
        all categories not-present and say so in the summary. The summary is one or two sentences naming \
        the scene and its key SIF risks.

        Return ONLY the structured assessment: a `summary` and an `assessments` array. Include every one of \
        the 13 categories, present or not, with explicit is_present / has_direct_control / \
        has_indirect_control booleans and the named control strings when true.
        """
    }

    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard {
        card(for: try report(from: json))
    }

    // MARK: - Domain helpers

    func report(from json: [String: Any], provenance: AIProvenance? = nil) throws -> SafetyReport {
        try SafetyReport.from(json: json, provenance: provenance)
    }

    /// Map the rich report onto the generic card (findings = present hazards; tier from worst control;
    /// score in the summary; top uncontrolled hazard as the recommended action).
    func card(for report: SafetyReport) -> AssessmentCard {
        let findings = report.present.map { f in
            AssessmentFinding(
                label: f.hazard.displayName,
                detail: Self.controlDetail(f),
                severity: Self.severity(for: f.controlStatus),
                region: f.evidence.first.flatMap { SafetyBoxMapping.normalizedRegion(for: $0.box) })
        }
        let tier = report.present.isEmpty
            ? AssessmentTier.ok
            : findings.reduce(AssessmentTier.ok) { AssessmentTier.escalated($0, $1.severity) }

        let summary = [report.summary, Self.scoreLine(report)]
            .filter { !$0.isEmpty }.joined(separator: " ")

        let action = report.topUncontrolled.map { "Add a direct control for \($0.hazard.displayName)." }

        // No `confidence` is passed: HECA's schema asks the model for control booleans, not for a
        // self-rating, so there is no reported confidence to carry — and an unreported one stays
        // unreported rather than becoming 100%.
        return AssessmentCard(
            kind: kind, title: title, tier: tier, summary: summary,
            findings: findings, recommendedAction: action,
            disclaimer: Self.disclaimer)
    }

    // MARK: - Mapping

    private static func severity(for status: ControlStatus) -> AssessmentTier {
        switch status {
        case .none: return .critical
        case .indirect: return .caution
        case .direct: return .ok
        }
    }

    private static func controlDetail(_ f: HazardFinding) -> String {
        var parts: [String]
        switch f.controlStatus {
        case .direct: parts = ["Direct control: \(f.directControl)"]
        case .indirect: parts = ["Indirect only: \(f.indirectControl)"]
        case .none: parts = ["No control"]
        }
        if !f.comments.isEmpty { parts.append(f.comments) }
        return parts.joined(separator: " — ")
    }

    private static func scoreLine(_ report: SafetyReport) -> String {
        guard let score = report.score else { return "No high-energy hazards detected in view." }
        let direct = report.present.filter { $0.controlStatus == .direct }.count
        // The percentage is a ratio of the hazards *in this one frame*, not a confidence — so it is
        // always said with the frame attached to it.
        return "HECA score \(Int((score * 100).rounded()))% — \(direct)/\(report.present.count) hazards visible in this camera view are directly controlled."
    }
}
