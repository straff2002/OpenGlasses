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

    /// Tools declared on one native turn (decision 3: at most five).
    static let perTurnLimit = FieldAssistLocalToolSet.perTurnLimit

    /// Whole-word cues that put an everyday tool ahead of the rest. Names only; an unlisted tool
    /// keeps its place in the registry's order.
    static let everydayCues: [String: [String]] = [
        "get_weather": ["weather", "rain", "forecast", "temperature", "outside", "wind"],
        "get_datetime": ["time", "date", "day", "today"],
        "set_timer": ["timer"],
        "set_alarm": ["alarm", "wake"],
        "calendar": ["calendar", "meeting", "appointment", "schedule"],
        "reminder": ["remind", "reminder"],
        "calculate": ["calculate", "plus", "minus", "times", "divided", "percent"],
        "where_am_i": ["where"],
        "music_control": ["music", "song", "play", "pause", "skip"],
        "flashlight": ["flashlight", "torch"],
        "brightness": ["brightness", "brighter", "dimmer"],
        "step_count": ["steps"],
    ]

    /// The names a native turn declares: the Field Assist set first (already ordered and cut by
    /// `FieldAssistLocalToolSet`), then the everyday tools the turn's words name, then the rest in
    /// the registry's order — at most `perTurnLimit`, each kept only while the definitions fit
    /// `budgetTokens`. Pure.
    ///
    /// The order returned is the turn's **priority order**, highest first, and it reaches the runtime
    /// as it is (`LocalToolTurn.tools`): when the definitions don't fit the prompt, the runtime's fit
    /// (`LocalToolFit`) drops from the end.
    static func nativeToolNames(field: [String], everyday: [String], utterance: String,
                                estimatedTokens: (String) -> Int, budgetTokens: Int) -> [String] {
        let ordered = ordered(field: field, everyday: everyday, utterance: utterance)
        var used = 0
        var kept: [String] = []
        for name in ordered where kept.count < perTurnLimit {
            let cost = estimatedTokens(name)
            guard used + cost <= budgetTokens else { continue }
            used += cost
            kept.append(name)
        }
        return kept
    }

    /// The priority order before any budget: `field` as given, then the everyday tools the turn's
    /// words name, then the rest in the given order. The device qualification app orders a case's
    /// offered tools with this, so its runs drop what a turn would drop. Pure.
    static func ordered(field: [String], everyday: [String], utterance: String) -> [String] {
        let words = Set(utterance.lowercased().split { !$0.isLetter }.map(String.init))
        let remaining = everyday.filter { !field.contains($0) }
        let hinted = remaining.filter { name in everydayCues[name]?.contains(where: words.contains) ?? false }
        return field + hinted + remaining.filter { !hinted.contains($0) }
    }
}
