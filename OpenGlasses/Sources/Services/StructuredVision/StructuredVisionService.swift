import Foundation
import UIKit
import Combine

/// Errors surfaced by `StructuredVisionService`.
enum StructuredVisionError: Error, LocalizedError {
    case unknownKind(String)
    case noFrame
    case analysisFailed

    var errorDescription: String? {
        switch self {
        case .unknownKind(let k): return "No assessment schema registered for '\(k)'."
        case .noFrame: return "No camera frame available."
        case .analysisFailed: return "The structured vision call returned no usable result."
        }
    }
}

/// Runs a structured-vision assessment end to end (structured-vision plan, Phase 3): grabs a camera
/// frame, calls the active provider's forced structured-output path, decodes against the chosen
/// schema, applies the deterministic backstop, and publishes the resulting `AssessmentCard` for the
/// card view + HUD. Configured by `AppState`, exactly like `NavigationAssistService` / `LiveCoachService`.
///
/// The LLM call is a settable `analyze` seam so the core (`assess(kind:imageData:note:)`) is unit-testable
/// without a network or a device. The `registry` is likewise injectable for tests.
@MainActor
final class StructuredVisionService: ObservableObject {
    static let shared = StructuredVisionService()

    @Published private(set) var latest: AssessmentCard?
    @Published private(set) var isAnalyzing = false

    /// Schema lookup — defaults to the shared registry; tests may swap in a fresh one.
    var registry: AssessmentSchemaRegistry = .shared

    /// The structured-vision call seam: (systemPrompt, userText, jpeg, jsonSchema, toolName) → JSON object.
    /// Set by `configure(...)` to call `LLMService.analyzeFrameStructured`; tests inject a fake.
    var analyze: ((String, String, Data, [String: Any], String) async -> [String: Any]?)?

    private weak var camera: CameraService?
    weak var glassesDisplay: GlassesDisplayService?

    init() {}

    /// Wire the live dependencies (called once at app launch).
    func configure(camera: CameraService, llm: LLMService, tts: TextToSpeechService) {
        self.camera = camera
        self.analyze = { [weak llm] systemPrompt, userText, imageData, jsonSchema, toolName in
            await llm?.analyzeFrameStructured(systemPrompt: systemPrompt, userText: userText,
                                              imageData: imageData, jsonSchema: jsonSchema, toolName: toolName)
        }
        registerBuiltinSchemas()
    }

    /// Register the built-in, domain-free schemas. Idempotent.
    func registerBuiltinSchemas() {
        if !registry.contains("instrument_reading") { registry.register(InstrumentReadingSchema()) }
        if !registry.contains("first_aid_triage") { registry.register(FirstAidTriageSchema()) }
    }

    /// Dismiss the currently presented card.
    func dismiss() { latest = nil }

    /// Publish an externally-produced card (e.g. from a domain service like HECA) so it renders in the
    /// shared card overlay and mirrors to the HUD.
    func present(_ card: AssessmentCard) {
        latest = card
        publish(card)
    }

    /// Where the once-per-session AI disclosure goes for the chat/voice surfaces. A closure rather
    /// than a direct TTS call so a headless test can observe it; `AppState` points it at the speech
    /// path. The HUD copy rides along on the card's own line rather than replacing it.
    var announceDisclosure: ((String) -> Void)?

    /// The session-scoped disclosure ledger. Injectable so a test gets a fresh session.
    var disclosureLedger: AIDisclosureLedger = .shared

    /// Mirror to the HUD, prefixing the AI disclosure the first time an assessment is presented in
    /// this session.
    private func publish(_ card: AssessmentCard) {
        let disclosure = disclosureLedger.consume(.assessment)
        if let disclosure { announceDisclosure?(disclosure) }
        mirrorToHUD(card, prefix: disclosure)
    }

    // MARK: - Core (testable)

    /// Assess a specific JPEG against `kind`. Decodes, backstops, publishes, and mirrors to the HUD.
    func assess(kind: String, imageData: Data, note: String?) async throws -> AssessmentCard {
        guard let schema = registry.schema(for: kind) else { throw StructuredVisionError.unknownKind(kind) }
        guard let analyze else { throw StructuredVisionError.analysisFailed }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let userText = note.map { "Assess the scene. Context: \($0)" } ?? "Assess the scene."

        // CJ item 4: category-only privacy reporting — every vertical gets the `sensitive_items`
        // capability at this one chokepoint (default on).
        var systemPrompt = schema.systemPrompt
        var jsonSchema = schema.jsonSchema
        if Config.visionPrivacyCategoriesEnabled {
            (systemPrompt, jsonSchema) = AssessmentPrivacy.augment(systemPrompt: systemPrompt, jsonSchema: jsonSchema)
        }
        // Every vertical is asked what it could not see, at the same chokepoint privacy reporting
        // uses, so a new schema inherits the uncertainty capability without knowing it exists.
        (systemPrompt, jsonSchema) = AssessmentPrompt.augmentingViewLimits(systemPrompt: systemPrompt,
                                                                          jsonSchema: jsonSchema)

        guard let json = await analyze(systemPrompt, userText, imageData, jsonSchema, "assessment") else {
            throw StructuredVisionError.analysisFailed
        }
        var card = try schema.makeCard(from: json, context: note)
        card = schema.backstop(card)
        if Config.visionPrivacyCategoriesEnabled {
            card = card.addingFindings(AssessmentPrivacy.findings(for: AssessmentPrivacy.reportedCategories(in: json)))
        }
        card = AssessmentQualifier.qualify(
            card,
            quality: InputQualityPolicy.evaluate(
                ImageQualityProbe.indicators(for: imageData)
                    .merging(InputQualityIndicators.fromModelPayload(json))),
            provenance: AIProvenance.forActiveModel(
                promptSources: [systemPrompt, AIProvenance.canonicalJSON(jsonSchema)]))
        latest = card
        publish(card)
        return card
    }

    // MARK: - Convenience (uses the live camera)

    /// Grab the current camera frame and assess it.
    func assessCurrentFrame(kind: String, note: String?) async throws -> AssessmentCard {
        guard let camera else { throw StructuredVisionError.noFrame }
        let data: Data
        if let frame = camera.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.7) {
            data = jpeg
        } else if let captured = try? await camera.capturePhoto() {
            data = captured
        } else {
            throw StructuredVisionError.noFrame
        }
        return try await assess(kind: kind, imageData: data, note: note)
    }

    // MARK: - HUD

    private func mirrorToHUD(_ card: AssessmentCard, prefix: String? = nil) {
        let icon: GlassesDisplayService.HUDIcon
        switch card.tier {
        case .unknown: icon = .info
        case .ok: icon = .success
        case .caution: icon = .warning
        case .critical: icon = .hazard
        }
        let body = AssessmentPresentation(card).spokenSummary
        glassesDisplay?.showNavigation(prefix.map { "\($0) \(body)" } ?? body, icon: icon)
    }
}
