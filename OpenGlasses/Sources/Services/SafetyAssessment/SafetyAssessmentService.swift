import Foundation
import UIKit
import Combine

/// Runs a HECA end to end (docs/plans/safety-assessment.md): grabs a job-site frame, calls the
/// structured-vision provider layer with the `SafetyAssessmentSchema`, decodes the rich `SafetyReport`
/// (all 13 hazards + score), and publishes the generic card via `StructuredVisionService` (card + HUD).
/// Configured by `AppState`. The LLM call is a settable `analyze` seam so the core is unit-testable.
/// Advisory only — not a certified inspection.
@MainActor
final class SafetyAssessmentService: ObservableObject {
    static let shared = SafetyAssessmentService()

    @Published private(set) var latest: SafetyReport?
    @Published private(set) var isAnalyzing = false

    let schema = SafetyAssessmentSchema()
    /// The still source — see `StructuredVisionService.camera` for why this is the chokepoint
    /// protocol rather than `CameraService`.
    weak var camera: (any FilteredStillProviding)?

    /// Where the generic result card is published — defaults to the shared service; tests inject a
    /// fresh one so they don't drive the host-app's real HUD/Wearables.
    var structuredVision: StructuredVisionService = .shared

    /// Where reports are persisted — defaults to the shared store; tests inject a temp-dir store.
    var store: SafetyAssessmentStore = .shared

    /// (systemPrompt, jpeg, jsonSchema, toolName) → JSON object. Set by `configure(...)`; tests inject a fake.
    var analyze: ((String, Data, [String: Any], String) async -> [String: Any]?)?

    /// Free-text image-seeded advisor call (systemPrompt, userText, jpeg) → answer. Set by `configure(...)`.
    var advise: ((String, String, Data) async -> String?)?

    /// Hook to log the assessment into an active Field-Assist session's audit log. Set by `configure(...)`.
    var sessionLog: ((SafetyReport) -> Void)?

    /// The last assessed frame — kept so the advisor can reason about the same scene.
    private(set) var lastImageData: Data?
    var lastImage: UIImage? { lastImageData.flatMap(UIImage.init(data:)) }

    init() {}

    func configure(camera: any FilteredStillProviding, llm: LLMService) {
        self.camera = camera
        self.analyze = { [weak llm] systemPrompt, imageData, jsonSchema, toolName in
            await llm?.analyzeFrameStructured(
                systemPrompt: systemPrompt,
                userText: "Assess this job-site scene for high-energy hazards.",
                imageData: imageData, jsonSchema: jsonSchema, toolName: toolName)
        }
        self.advise = { [weak llm] systemPrompt, userText, imageData in
            await llm?.analyzeFrame(systemPrompt: systemPrompt, userText: userText, imageData: imageData, maxTokens: 400)
        }
        self.sessionLog = { report in
            guard FieldSessionService.shared.isSessionActive else { return }
            FieldSessionService.shared.logSafetyAssessment(
                summary: SafetyAssessmentService.summaryText(report), score: report.score)
        }
    }

    /// Assess a specific JPEG. Decodes the report, publishes the generic card, returns the report.
    func assess(imageData: Data) async throws -> SafetyReport {
        guard let analyze else { throw StructuredVisionError.analysisFailed }
        isAnalyzing = true
        defer { isAnalyzing = false }
        lastImageData = imageData

        let (systemPrompt, jsonSchema) = AssessmentPrompt.augmentingViewLimits(
            systemPrompt: schema.systemPrompt, jsonSchema: schema.jsonSchema)
        guard let json = await analyze(systemPrompt, imageData, jsonSchema, "safety_assessment") else {
            throw StructuredVisionError.analysisFailed
        }
        let provenance = AIProvenance.forActiveModel(
            promptSources: [systemPrompt, AIProvenance.canonicalJSON(jsonSchema)])
        let report = try schema.report(from: json, provenance: provenance)
        latest = report
        store.save(report)
        sessionLog?(report)
        // The HECA card goes through the same uncertainty gate every other vertical does: a blurry,
        // dark or partly-blocked job-site frame does not produce a clean score with a green tick.
        structuredVision.present(AssessmentQualifier.qualify(
            schema.card(for: report),
            quality: InputQualityPolicy.evaluate(
                ImageQualityProbe.indicators(for: imageData)
                    .merging(InputQualityIndicators.fromModelPayload(json))),
            provenance: provenance))
        return report
    }

    /// Grab the current camera frame and assess it.
    func assessCurrentFrame() async throws -> SafetyReport {
        guard let camera else { throw StructuredVisionError.noFrame }
        // A job-site frame is the most populated frame this app takes, and it is about to be sent
        // to a cloud model. Filtered under `.visionAssessment`, or not assessed at all.
        guard let data = await camera.filteredStill(for: .visionAssessment,
                                                    source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.7) else {
            throw StructuredVisionError.noFrame
        }
        return try await assess(imageData: data)
    }

    // MARK: - Image-seeded advisor

    /// Answer a follow-up about the last assessed scene, keeping the frame + findings in context.
    func ask(_ question: String) async -> String {
        guard let report = latest, let imageData = lastImageData else {
            return "Run a safety assessment first (say \"assess this site\"), then ask your question."
        }
        guard let advise else { return "The safety advisor isn't available right now." }
        let answer = await advise(Self.advisorSystemPrompt, Self.advisorUserText(report: report, question: question), imageData)
        return answer ?? "I couldn't get an answer just now — this is advisory only; verify on site."
    }

    static let advisorSystemPrompt = """
    You are a calm, collaborative occupational-safety partner talking a worker through a job site — like \
    talking on the radio. You are looking at the same scene they just assessed (image attached) plus its \
    HECA findings. Help them decide whether a control is truly DIRECT (engineered, targeted, effective even \
    if a worker makes a mistake) vs INDIRECT (training, signage, PPE, spotters), and suggest specific direct \
    controls. Be concise and practical. ADVISORY ONLY — never claim a real-world action was taken or that the \
    site is certified safe; if there's a life-threat, tell them to stop work and get the right help.
    """

    static func advisorUserText(report: SafetyReport, question: String) -> String {
        var ctx = ["Latest HECA findings:"]
        if report.present.isEmpty {
            ctx.append("- No high-energy hazards were detected.")
        } else {
            for f in report.present {
                let control = f.controlStatus == .direct ? f.directControl
                    : (f.controlStatus == .indirect ? f.indirectControl : "none")
                ctx.append("- \(f.hazard.displayName): \(f.controlStatus.rawValue) control (\(control.isEmpty ? "—" : control))")
            }
        }
        ctx.append("")
        ctx.append("Question: \(question)")
        return ctx.joined(separator: "\n")
    }

    /// A concise, speakable summary of a report for the tool to relay.
    static func summaryText(_ report: SafetyReport) -> String {
        var lines = [report.summary.isEmpty ? "Site assessed." : report.summary]
        if let score = report.score {
            let direct = report.present.filter { $0.controlStatus == .direct }.count
            lines.append("HECA score \(Int((score * 100).rounded()))% — \(direct)/\(report.present.count) hazards visible in this camera view are directly controlled.")
        } else {
            lines.append("No high-energy hazards detected in view.")
        }
        for f in report.uncontrolled {
            let tag = f.controlStatus == .none ? "UNCONTROLLED" : "indirect-only"
            lines.append("\(tag): \(f.hazard.displayName)")
        }
        // Spoken and relayed everywhere the summary goes, so the escalation is not something only a
        // reader of the PDF ever sees.
        lines.append(AssessmentEscalation.line(forKind: "safety_assessment"))
        return lines.joined(separator: "\n")
    }
}
