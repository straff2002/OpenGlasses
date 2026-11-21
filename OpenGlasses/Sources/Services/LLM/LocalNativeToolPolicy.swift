import Foundation

/// Which downloaded models take their tools natively, and which get the Field Assist tools (Plan MQ
/// P1). Pure.
///
/// **Native tool calls** — the turn's tools passed as `ToolSpec`s for the model's own chat template
/// to render, its calls read from mlx-swift-lm's parsers, and the bounded `LocalToolLoop` in place
/// of the single shot — run only when `Config.localNativeToolCallsEnabled` is on **and** the model
/// is on `allowlist` (decision 1: one model at a time, starting with Gemma 4 E2B) **and** it runs on
/// MLX. GGUF has no tool parsing yet (P2).
///
/// **Field Assist tools** go to a model that has earned them on a phone
/// (`LocalModelCatalog.qualifiesForFieldAssistTools`, evidence only) or, with the flag on, to an
/// allowlisted model **under qualification**: the owner can try it on the job before any badge is
/// earned. The badge rule is untouched; being under qualification shows nothing in the catalog.
enum LocalNativeToolPolicy {

    /// Decision 1: per model, starting with Gemma 4 E2B. Compared without case: the catalog spells
    /// the checkpoint `gemma-4-e2b`, and a hub snapshot can be `gemma-4-E2B`.
    static let allowlist: Set<String> = [
        "mlx-community/gemma-4-e2b-it-4bit",
    ]

    static func isAllowlisted(_ modelID: String) -> Bool {
        allowlist.contains(modelID.lowercased())
    }

    /// The turn runs native tool calls and the loop.
    static func usesNativeToolCalls(modelID: String, runtime: LocalModelRuntime, flagOn: Bool) -> Bool {
        flagOn && runtime == .mlx && isAllowlisted(modelID)
    }

    /// The model is offered the Field Assist tools while Field Assist is on: qualified by evidence,
    /// or under qualification with the flag on.
    static func offersFieldAssistTools(modelID: String, runtime: LocalModelRuntime, flagOn: Bool,
                                       qualified: Bool) -> Bool {
        qualified || usesNativeToolCalls(modelID: modelID, runtime: runtime, flagOn: flagOn)
    }
}
