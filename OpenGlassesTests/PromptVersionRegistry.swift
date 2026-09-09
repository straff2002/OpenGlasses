import Foundation
@testable import OpenGlasses

/// The set of instruction versions a safety evaluation is valid for (W08.4).
///
/// A prompt change is a behaviour change. The corpus was evaluated against one set of instructions,
/// and the moment those instructions move, every result in the last run describes an app that no
/// longer exists. Nothing made that visible: a prompt could be edited in a pull request that touched
/// no test, and the gate would go green on a corpus measured against the previous wording.
///
/// This registry computes, for every registered assessment schema, exactly the digest the live path
/// attaches to a card's provenance. `PromptVersionRegistryTests` snapshots those digests beside the
/// corpus; a digest that moves without the corpus version moving with it fails, which is the
/// mechanism that turns a prompt edit into a re-evaluation.
enum PromptVersionRegistry {

    /// Every schema the app registers, in a stable order.
    static let schemas: [AssessmentSchema] = [
        SafetyAssessmentSchema(),
        FirstAidTriageSchema(),
        InstrumentReadingSchema(),
    ]

    /// The augmented prompt and schema for one vertical — the chokepoint augmentations applied in
    /// the order `StructuredVisionService.assess` applies them.
    ///
    /// Privacy reporting is included unconditionally rather than read from `Config`. It ships
    /// enabled, and a snapshot that changed depending on a developer's local preference would be a
    /// snapshot of the developer, not the build. Turning the preference off is a documented
    /// configuration, not a prompt version.
    static func instructions(for schema: AssessmentSchema) -> (systemPrompt: String, jsonSchema: [String: Any]) {
        var prompt = schema.systemPrompt
        var json = schema.jsonSchema
        (prompt, json) = AssessmentPrivacy.augment(systemPrompt: prompt, jsonSchema: json)
        (prompt, json) = AssessmentPrompt.augmentingViewLimits(systemPrompt: prompt, jsonSchema: json)
        return (prompt, json)
    }

    /// vertical id → the 16-character instruction digest.
    static func digests() -> [String: String] {
        var out: [String: String] = [:]
        for schema in schemas {
            let (prompt, json) = instructions(for: schema)
            out[schema.kind] = AIProvenance.promptDigest(systemPrompt: prompt, jsonSchema: json)
        }
        // The two answering paths that carry a named prompt identity rather than a schema. They
        // have no JSON schema to hash, so the identity constant is the version — which means it has
        // to be bumped by hand when the behaviour changes, and this records what it was last set to.
        out["field_assist_answering"] = AIProvenance.digest(of: [FieldAssistProvenance.promptIdentity])
        out["agent_conversation"] = AIProvenance.digest(of: [AgentArchiveProvenance.promptIdentity])
        return out
    }
}
