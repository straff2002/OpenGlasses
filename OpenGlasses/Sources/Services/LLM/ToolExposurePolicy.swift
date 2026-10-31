import Foundation

// MARK: - On-demand tool schemas (Plan IU)
//
// Every request used to carry the full JSON schema of every enabled tool — about 120 native tools
// plus whatever MCP servers offer. A tester's ChatGPT turns weighed the tools block at ~76 KB on
// every round trip. On a model with a large window that is a rounding error the provider caches;
// on an on-device or small-window model it is most of the room the conversation has.
//
// The rule, decided by the owner and stated once here:
//
//   - The prompt keeps the compact list of every available tool (names, and on-demand a one-line
//     summary each), so the model always knows what it can reach.
//   - **Full** exposure declares every schema — today's behaviour, byte for byte.
//   - **Core** exposure declares a small everyday set, the tools an active mode needs, every tool
//     already used or looked up in this conversation, and `lookup_tools`, which returns the full
//     definition of named tools. A looked-up tool is declared from the next model round onward.
//   - **Automatic** (the default) is core only when the full set would take more than a tenth of
//     the model's context window. It is a context rule, never a model-quality rule. Always is core
//     for every model; Never is full for every model. An organisation profile can pin the mode.
//
// Pure: every input is a value, so every row of the table is a unit test.

/// The wearer's (or the organisation's) choice of when tool definitions go on demand.
enum ToolDefinitionsMode: String, CaseIterable, Identifiable, Sendable {
    /// On demand only when every tool's definition would crowd the model's context.
    case automatic
    /// On demand for every model.
    case always
    /// Every definition with every request — the behaviour before the setting existed.
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic (Recommended)")
        case .always: return String(localized: "Always")
        case .never: return String(localized: "Never")
        }
    }
}

/// How much of the tool set a turn declares in full.
enum ToolExposure: String, Equatable, Sendable {
    /// Every available tool's schema, as before.
    case full
    /// The core set, plus tools used or looked up in this conversation, plus `lookup_tools`.
    case core
}

/// Why a turn got the exposure it did. Logged as a token, so the support report can tell a
/// wearer's choice from the context rule.
enum ToolExposureReason: String, Equatable, Sendable {
    /// Always or Never, by the wearer or pinned by the organisation.
    case setting
    /// Automatic, decided by the full set's share of the context window (either way).
    case contextShare
    /// Automatic with no known context window for the model: today's full list is kept.
    case `default`
    /// The on-device path, which has always carried its own reduced list (`localSafeTools`) and
    /// is outside the setting.
    case onDevice
}

/// What a turn declares and why. Fixed at turn start — a turn in flight keeps the mode it began
/// with — except that `core` grows as tools are looked up (`ToolExposurePolicy.roundDeclared`).
struct ToolExposureDecision: Equatable, Sendable {
    let exposure: ToolExposure
    let reason: ToolExposureReason
    /// Every tool the model could be given right now (native + MCP; the OpenClaw `execute` tool
    /// is declared outside this set and is never on demand).
    let available: Set<String>
    /// The names declared from the first round. All of `available` when `full`; for `core`, the
    /// core set and what this conversation already used or looked up, within `available`.
    let declared: Set<String>
    /// The estimated size of the full set, in tokens (`ToolExposurePolicy.estimatedTokens`).
    let fullSetTokens: Int
    /// The context window the rule was measured against, when one is known.
    let contextWindow: Int?
}

enum ToolExposurePolicy {

    /// The share of the context window the full tool set may take before Automatic goes on
    /// demand: a tenth.
    static let automaticShareDenominator = 10

    /// The house estimate — four characters to a token (`HistoryHygiene`, `HandoffTranscriptBridge`,
    /// `MemoryContextSnapshot` use the same). JSON schemas are ASCII, so bytes are characters.
    static func estimatedTokens(bytes: Int) -> Int { max(0, bytes) / 4 }

    /// Whether a full set of `fullSetTokens` crowds a `contextWindow`-token model: strictly more
    /// than a tenth of it.
    static func crowds(fullSetTokens: Int, contextWindow: Int) -> Bool {
        guard contextWindow > 0 else { return true }
        return fullSetTokens * automaticShareDenominator > contextWindow
    }

    /// The decision for one turn.
    ///
    /// - Parameters:
    ///   - mode: the setting in force (the organisation's pin already applied).
    ///   - available: every declarable tool name right now.
    ///   - fullSetBytes: the serialized size of every available declaration.
    ///   - contextWindow: the model's window in tokens, nil when not known.
    ///   - core: the core set for this turn (`ToolExposureCore.names`), not yet intersected.
    ///   - remembered: tools this conversation already used or looked up.
    static func decide(mode: ToolDefinitionsMode, available: [String], fullSetBytes: Int,
                       contextWindow: Int?, core: Set<String>,
                       remembered: Set<String>) -> ToolExposureDecision {
        let availableSet = Set(available)
        let tokens = estimatedTokens(bytes: fullSetBytes)
        let exposure: ToolExposure
        let reason: ToolExposureReason
        switch mode {
        case .never:
            (exposure, reason) = (.full, .setting)
        case .always:
            (exposure, reason) = (.core, .setting)
        case .automatic:
            if let window = contextWindow {
                exposure = crowds(fullSetTokens: tokens, contextWindow: window) ? .core : .full
                reason = .contextShare
            } else {
                (exposure, reason) = (.full, .default)
            }
        }
        let declared = exposure == .full
            ? availableSet
            : core.union(remembered).intersection(availableSet)
        return ToolExposureDecision(exposure: exposure, reason: reason, available: availableSet,
                                    declared: declared, fullSetTokens: tokens,
                                    contextWindow: contextWindow)
    }

    /// The names a model round declares: nil for full exposure (no filter), else the turn's
    /// declared set, everything promoted since, and the lookup tool — within what is available.
    static func roundDeclared(_ decision: ToolExposureDecision, promoted: Set<String>) -> Set<String>? {
        guard decision.exposure == .core else { return nil }
        return decision.declared.union(promoted.intersection(decision.available))
    }

    /// Whether a call names a tool the model may have but was not given the definition of in the
    /// round it was made in. Such a call is never run on arguments written without the schema
    /// (`undeclaredCallMessage`); a name outside `available` is the router's to refuse as before.
    static func isUndeclaredCall(_ name: String, declaredThisRound: Set<String>?,
                                 available: Set<String>) -> Bool {
        guard let declaredThisRound else { return false }
        return available.contains(name) && !declaredThisRound.contains(name)
    }

    /// What the model is told about a call to a tool whose definition it did not have. Nothing
    /// ran, so it is safe to call again — and the definition rides on the next request.
    static func undeclaredCallMessage(_ name: String) -> String {
        "'\(name)' was not run: its definition was not attached yet, so its arguments could not be "
            + "checked. Its full definition is attached from your next step. Call it again with "
            + "arguments that match that definition."
    }

    /// The names a `lookup_tools` call asked for, as given: an array of strings or one
    /// comma-separated string. Trimmed, empty entries dropped, de-duplicated in order.
    static func requestedNames(_ args: [String: Any]) -> [String] {
        let raw: [String]
        if let list = args["names"] as? [String] {
            raw = list
        } else if let list = args["names"] as? [Any] {
            raw = list.compactMap { $0 as? String }
        } else if let text = args["names"] as? String {
            raw = text.split(separator: ",").map(String.init)
        } else if let one = args["name"] as? String {
            raw = [one]
        } else {
            raw = []
        }
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - The core set

/// The tools declared in full whatever the exposure, chosen from evidence rather than taste:
///
/// - **Everyday asks** — the on-device path's safe set (`LLMService.localSafeTools`: weather,
///   time, timers, alarms, calendar, reminders, location, device, music), the Voice tab's home grid
///   (`HomeGridCatalog`: calendar, reminders, brief, weather, quick note, timer, scan a document,
///   read text), and the "general essentials" half of the field profile (`FieldToolProfile.names`:
///   web search, directions, nearby places, calls, messages, contacts, notes, units, maths).
/// - **Seeing** — `capture_photo` (a turn that says "look at this" attaches a still on its own, but
///   an explicit photo is this tool) and `look_closely`.
/// - **Memory** — `memory_search` and `brain` for recall, and `remember_scene` for explicit camera
///   memories. Spoken facts use the `[REMEMBER]` tag in the prompt.
/// - **Control** — `new_topic` and `yield_to_human`, which change how the loop itself behaves.
/// - **Mandatory routing** — `health_check`, which the prompt's routing rule says MUST be called.
///
/// An active mode adds the tools it is built on: a Field Assist job adds the whole field profile,
/// accessibility mode its sight tools. `lookup_tools` is added by the declarations themselves.
/// A vault-only job takes out what `VaultOnlyPolicy` seals, which `web_search` and `get_news` here are.
enum ToolExposureCore {

    static let everyday: Set<String> = [
        // Time, timers, reminders, calendar.
        "get_datetime", "set_timer", "set_alarm", "reminder", "calendar", "daily_briefing",
        // Weather, place and getting about.
        "get_weather", "where_am_i", "find_nearby", "get_directions", "navigate",
        // Looking things up.
        "web_search", "get_news",
        // The phone and the glasses.
        "device_info", "flashlight", "brightness", "music_control", "play_podcast",
        // Notes and memory.
        "save_note", "list_notes", "memory_search", "brain", "remember_scene",
        // People.
        "phone_call", "send_message", "lookup_contact",
        // Seeing.
        "capture_photo", "look_closely",
        // Arithmetic and units.
        "calculate", "convert_units", "translate",
        // The loop's own controls.
        "new_topic", "yield_to_human",
        // Named by the prompt's mandatory routing rule (`SystemPromptBuilder.routingRules`).
        "health_check",
    ]

    /// The sight tools accessibility mode registers (`NativeToolRegistry`).
    static let accessibility: Set<String> = [
        "reading_assist", "navigation_assist", "identify_color", "identify_money",
    ]

    /// The core set for a turn. Pure.
    static func names(fieldJobActive: Bool, accessibilityMode: Bool, vaultOnly: Bool = false) -> Set<String> {
        var names = everyday
        if fieldJobActive { names.formUnion(FieldToolProfile.names) }
        if accessibilityMode { names.formUnion(accessibility) }
        return vaultOnly ? names.filter { !VaultOnlyPolicy.isSealed(tool: $0) } : names
    }
}

// MARK: - Context windows

/// The context window a cloud model is measured against, from what the app already knows: the
/// ChatGPT subscription's account catalog and table, the OpenAI API's model pages
/// (`RequestContextBudget`), and the on-device budget (`LocalModelBudget`). The other providers
/// had no window anywhere in the app, so a small family table is added here, read from each
/// provider's model pages — and a model it does not know answers nil, which keeps today's full
/// list (`ToolExposureReason.default`).
enum ModelContextWindow {

    struct Window: Equatable, Sendable {
        let tokens: Int
        let provenance: String
    }

    /// The family table for providers with no window elsewhere: (provider, model-id prefix,
    /// window), most specific first. Nil for anything not in it.
    static func familyWindow(provider: LLMProvider, model: String) -> Window? {
        let id = model.lowercased().trimmingCharacters(in: .whitespaces)
        let rows: [(LLMProvider, String, Int)] = [
            // Claude: 200k standard across the current families (a 1M window is an opt-in beta).
            (.anthropic, "claude-", 200_000),
            // Gemini 1.0 was 32k; 1.5 onward is ~1M.
            (.gemini, "gemini-1.0", 32_768),
            (.gemini, "gemini-", 1_048_576),
            (.geminiVertex, "gemini-1.0", 32_768),
            (.geminiVertex, "gemini-", 1_048_576),
            (.deepseek, "deepseek-", 128_000),
            (.mistral, "", 128_000),
            (.groq, "", 131_072),
        ]
        guard let row = rows.first(where: { $0.0 == provider && id.hasPrefix($0.1) }) else { return nil }
        return Window(tokens: row.2, provenance: "providerFamilyTable20261017")
    }

    /// The window for a cloud model config, or nil when the app does not know one.
    ///
    /// - Parameter chatGPTCatalogContext: the account catalog's window for a ChatGPT model, read
    ///   by the caller (it lives behind the OAuth account), nil elsewhere.
    static func resolve(provider: LLMProvider, model: String, baseURL: String,
                        chatGPTCatalogContext: Int? = nil) -> Window? {
        switch provider {
        case .chatgpt:
            let endpoint = baseURL.isEmpty ? ChatGPTOAuth.backendResponsesURL : baseURL
            let limit = RequestContextBudget.resolve(model: model, endpoint: endpoint,
                                                     catalogContext: chatGPTCatalogContext)
            return Window(tokens: limit.context, provenance: limit.provenance)
        case .openai:
            let endpoint = OpenAIRouteSelector.endpointURL(baseURL: baseURL, endpoint: .responses)
            guard URL(string: endpoint)?.host?.lowercased() == OpenAIRouteSelector.apiHost else {
                // Azure and other hosts: limits are per deployment, not per model id.
                return nil
            }
            let limit = RequestContextBudget.resolve(model: model, endpoint: endpoint)
            return Window(tokens: limit.context, provenance: limit.provenance)
        case .local:
            return Window(tokens: LocalModelBudget.contextWindow(for: model), provenance: "localModelBudget")
        case .appleOnDevice:
            return Window(tokens: LocalModelBudget.defaultContextWindow, provenance: "localModelBudget")
        default:
            return familyWindow(provider: provider, model: model)
        }
    }
}

// MARK: - The turn in flight

/// One turn's exposure, held task-locally for the length of the turn (`ToolExposureScope`) so the
/// provider loops and the tool dispatcher read the decision the turn started with, whatever the
/// setting does meanwhile.
@MainActor
final class ToolExposureTurn {
    let decision: ToolExposureDecision
    /// What the latest model round declared: nil for full exposure. Recorded when a round builds
    /// its tools, read by the dispatcher's safety net — the set a call was *written against*, not
    /// the set as it grew during the round.
    var declaredThisRound: Set<String>?

    init(decision: ToolExposureDecision) {
        self.decision = decision
    }
}

enum ToolExposureScope {
    @TaskLocal static var turn: ToolExposureTurn?
}
