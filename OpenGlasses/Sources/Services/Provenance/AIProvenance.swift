import Foundation
import CoreGraphics
import CryptoKit

/// Machine-readable provenance for anything an AI model produced (W08.3).
///
/// Every artifact the app hands to somebody else — a card, an exported audit record, a work-order
/// PDF, the wearer's own archive — should say what made it. Not as a disclaimer sentence a reader
/// may or may not notice, but as a field a machine can read back: which model, whether it ran on
/// the device or in somebody's cloud, which version of the instructions it was given, when, and
/// which build of this app.
///
/// **`promptVersionDigest` is a digest, never the prompt.** The system prompt and the JSON schema
/// are the app's own instructions, and a first-aid or safety prompt describes the domain in detail;
/// putting the body in an export would leak it into every share sheet the wearer taps. The digest
/// identifies the version — two exports from the same build and schema carry the same value — while
/// carrying none of the text. The same rule holds for source documents: a citation names them, the
/// provenance block does not reproduce them.
struct AIProvenance: Codable, Equatable {

    /// Where the inference physically ran. Not "which vendor" — the question a reader actually has
    /// is whether the frame left the device.
    enum ProviderClass: String, Codable {
        /// Ran on somebody else's server.
        case cloud
        /// Ran on this device.
        case local
        /// Both, in one result (a local pass plus a cloud pass, or a cascade that crossed).
        case mixed
    }

    /// The model as the provider names it, e.g. `claude-sonnet-4-5`. Never a display name.
    let modelIdentifier: String
    let providerClass: ProviderClass
    /// A short digest of the instructions the model was given — the system prompt plus the response
    /// schema. Identifies the version; reveals nothing about the content.
    let promptVersionDigest: String
    /// Whole seconds, always. The block travels inside documents whose encoders use different date
    /// strategies, and a timestamp that survives one round trip but not another makes two copies of
    /// the same record unequal — which is exactly what the field session export's round-trip test
    /// caught. It is truncated on construction and written as an ISO-8601 string of its own, so the
    /// value that comes back is the value that went in whatever the containing document does.
    let generatedAt: Date
    /// Always true. Present as an explicit field so a reader parsing the JSON does not have to infer
    /// AI authorship from the presence of the block.
    let isAIGenerated: Bool
    let appVersion: String

    init(modelIdentifier: String,
         providerClass: ProviderClass,
         promptVersionDigest: String,
         generatedAt: Date = Date(),
         appVersion: String = AIProvenance.currentAppVersion) {
        self.modelIdentifier = modelIdentifier
        self.providerClass = providerClass
        self.promptVersionDigest = promptVersionDigest
        self.generatedAt = Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down))
        self.isAIGenerated = true
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case modelIdentifier = "model_identifier"
        case providerClass = "provider_class"
        case promptVersionDigest = "prompt_version_digest"
        case generatedAt = "generated_at"
        case isAIGenerated = "is_ai_generated"
        case appVersion = "app_version"
    }

    /// Whole-second ISO-8601, with no fractional part to lose.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelIdentifier, forKey: .modelIdentifier)
        try c.encode(providerClass, forKey: .providerClass)
        try c.encode(promptVersionDigest, forKey: .promptVersionDigest)
        try c.encode(Self.timestampFormatter.string(from: generatedAt), forKey: .generatedAt)
        try c.encode(isAIGenerated, forKey: .isAIGenerated)
        try c.encode(appVersion, forKey: .appVersion)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelIdentifier = try c.decode(String.self, forKey: .modelIdentifier)
        providerClass = try c.decodeIfPresent(ProviderClass.self, forKey: .providerClass) ?? .cloud
        promptVersionDigest = try c.decodeIfPresent(String.self, forKey: .promptVersionDigest) ?? ""
        let stamp = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        generatedAt = stamp.flatMap(Self.timestampFormatter.date(from:)) ?? Date(timeIntervalSince1970: 0)
        isAIGenerated = true
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
    }

    // MARK: - Construction

    /// Build provenance for one structured-vision call. `promptSources` are hashed together and
    /// discarded; nothing but the digest survives this call.
    static func forAssessment(modelIdentifier: String,
                              providerClass: ProviderClass,
                              promptSources: [String],
                              generatedAt: Date = Date(),
                              appVersion: String = AIProvenance.currentAppVersion) -> AIProvenance {
        AIProvenance(modelIdentifier: modelIdentifier,
                     providerClass: providerClass,
                     promptVersionDigest: digest(of: promptSources),
                     generatedAt: generatedAt,
                     appVersion: appVersion)
    }

    /// A short, stable digest of the instruction set. Truncated to 16 hex characters: enough to tell
    /// two prompt versions apart in an audit, short enough to print in a PDF footer.
    static func digest(of sources: [String]) -> String {
        let joined = sources.joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Whether a model runs on the device. The two on-device backends are the only `local` ones;
    /// everything else leaves the device, and an unrecognised provider is assumed to.
    static func providerClass(for provider: LLMProvider) -> ProviderClass {
        switch provider {
        case .local, .appleOnDevice: return .local
        case .anthropic, .openai, .chatgpt, .gemini, .geminiVertex, .groq, .zai, .qwen,
             .minimax, .xai, .openrouter, .custom: return .cloud
        }
    }

    static var currentAppVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// Provenance for the model currently selected in settings, or `nil` when none is configured —
    /// an absent model identifier is left absent rather than filled with a guess.
    static func forActiveModel(promptSources: [String], generatedAt: Date = Date()) -> AIProvenance? {
        guard let model = Config.activeModel, !model.model.isEmpty else { return nil }
        return forAssessment(modelIdentifier: model.model,
                             providerClass: providerClass(for: model.llmProvider),
                             promptSources: promptSources,
                             generatedAt: generatedAt)
    }

    // MARK: - Rendering

    /// The one-line human form printed in a PDF footer or a JSON-adjacent header.
    var footerLine: String {
        let stamp = Self.timestampFormatter.string(from: generatedAt)
        return "AI-generated by \(modelIdentifier) (\(providerClass.rawValue)) · instructions \(promptVersionDigest) · \(stamp) · OpenGlasses \(appVersion)"
    }

    /// The whole-second ISO-8601 form, for manifests and footers.
    var isoTimestamp: String { Self.timestampFormatter.string(from: generatedAt) }

    /// PDF document metadata keys, for `UIGraphicsPDFRendererFormat.documentInfo`.
    var pdfDocumentInfo: [String: Any] {
        [
            kCGPDFContextCreator as String: "OpenGlasses \(appVersion) — AI-generated",
            kCGPDFContextSubject as String: footerLine,
        ]
    }
}

/// Prompt identity for the Field Assist answering path (W08.3).
///
/// Field Assist answers are produced over a session's whole conversation, not one schema call, so
/// there is no single system prompt to digest at export time. What the record needs is a stable
/// version identifier for the instruction set that produced those turns — this constant is that
/// identifier, and it changes when the answering behaviour does. It is deliberately a short name
/// rather than the prompt text: the digest goes in the export, the instructions never do.
enum FieldAssistProvenance {
    /// Bump when the Field Assist answering prompt or its citation contract changes.
    static let promptIdentity = "field-assist-answering-v1"
}

/// The `provenance.json` the wearer's agent archive carries (W08.3).
///
/// The archive is the most concentrated copy of the wearer's data the app can produce, and a large
/// part of it — every assistant turn in every conversation — was written by a model. Anyone reading
/// the archive later, including the wearer, should be able to tell which parts those are and what
/// wrote them, without opening a conversation and guessing.
enum AgentArchiveProvenance {
    /// Bump when the assistant's system-prompt construction changes materially.
    static let promptIdentity = "agent-conversation-v1"

    /// The manifest written to `provenance.json`. Present even when no model is configured, because
    /// "we do not know which model wrote these" is itself the answer a reader needs.
    static func manifest(_ provenance: AIProvenance?) -> [String: Any] {
        var manifest: [String: Any] = [
            "is_ai_generated": true,
            "applies_to": ["conversations/", "memory.md", "soul.md", "skills.md"],
            "note": "Assistant turns and generated agent documents in this archive were produced by an AI model. Prompt bodies and source documents are deliberately not included; only a digest identifying the instruction version is.",
        ]
        guard let provenance else {
            manifest["model_identifier"] = "unrecorded"
            manifest["provider_class"] = "unknown"
            manifest["app_version"] = AIProvenance.currentAppVersion
            return manifest
        }
        manifest["model_identifier"] = provenance.modelIdentifier
        manifest["provider_class"] = provenance.providerClass.rawValue
        manifest["prompt_version_digest"] = provenance.promptVersionDigest
        manifest["generated_at"] = provenance.isoTimestamp
        manifest["app_version"] = provenance.appVersion
        return manifest
    }
}
