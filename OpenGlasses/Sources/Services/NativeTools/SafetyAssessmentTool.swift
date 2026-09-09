import Foundation

/// `safety_assessment` — Field-Assist (B2B) HECA tool. Runs a High-Energy Control Assessment on the
/// current job-site view from the glasses camera: detects the 13 high-energy (SIF-capable) hazards and
/// whether each has a DIRECT control, and returns a summary + HECA score. Delegates to
/// `SafetyAssessmentService.shared` (which also publishes the result card + HUD). Advisory only.
@MainActor
struct SafetyAssessmentTool: NativeTool {
    let name = "safety_assessment"

    let description = """
    Run a High-Energy Control Assessment (HECA) on the current job-site view from the glasses camera — \
    detects the 13 high-energy serious-injury/fatality hazards and whether each is safeguarded by a DIRECT \
    control, and returns a summary plus a HECA score. Use for "assess this site", "is this safe?", "safety \
    check". Actions: run (assess now), last (repeat the latest result), score (just the latest HECA score), \
    history (recent assessments), export (PDF of the latest report), ask (image-seeded safety-advisor \
    follow-up about the last scene — pass 'question'). Advisory only — verify on site; not a certified inspection.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["run", "last", "score", "history", "export", "ask"],
                    "description": "run, last, score, history, export (PDF), or ask (advisor follow-up — needs 'question')."
                ],
                "question": [
                    "type": "string",
                    "description": "For action=ask: the safety follow-up question about the last assessed scene."
                ]
            ],
            "required": [] as [String]
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.safetyAssessment) else {
            return AIFeatureGate.disabledMessage(.safetyAssessment)
        }
        let service = SafetyAssessmentService.shared
        switch (args["action"] as? String ?? "run").lowercased() {
        case "last":
            guard let report = service.latest else {
                return "No safety assessment yet. Say \"assess this site\" to run one."
            }
            return SafetyAssessmentService.summaryText(report)
        case "score":
            guard let report = service.latest else {
                return "No safety assessment yet. Say \"assess this site\" to run one."
            }
            guard let score = report.score else { return "No high-energy hazards detected in the last assessment." }
            return "HECA score \(Int((score * 100).rounded()))% — \(report.uncontrolled.count) of \(report.present.count) present hazards lack a direct control."
        case "history":
            let recent = service.store.history.prefix(5)
            guard !recent.isEmpty else { return "No saved safety assessments yet." }
            let lines = recent.map { r -> String in
                let s = r.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
                return "• HECA \(s) — \(r.present.count) hazard(s): \(r.summary)"
            }
            return "Recent safety assessments:\n" + lines.joined(separator: "\n")
        case "export":
            guard let report = service.latest else {
                return "No safety assessment to export yet. Say \"assess this site\" first."
            }
            do {
                let lease = try SafetyReportPDF.makeLease(for: report)
                return "Prepared the safety report PDF: \(lease.displayName). It's held in protected storage for up to an hour and then cleared."
            } catch {
                return "Couldn't create the PDF: \(error.localizedDescription)"
            }
        case "ask":
            let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !question.isEmpty else { return "What would you like to ask about the site?" }
            return await service.ask(question)
        default:
            do {
                let report = try await service.assessCurrentFrame()
                return SafetyAssessmentService.summaryText(report)
            } catch StructuredVisionError.noFrame {
                return "I couldn't get a camera view of the site. Point the glasses at the work area and try again."
            } catch {
                return "Safety assessment failed: \(error.localizedDescription)"
            }
        }
    }
}
