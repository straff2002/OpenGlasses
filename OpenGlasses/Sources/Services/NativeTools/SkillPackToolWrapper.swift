import Foundation

/// Plan BX P1 — one skill-pack action as a `NativeTool`, merged into the registry so both prompt
/// builders and both tool routers reach it with zero new plumbing (the `CustomToolWrapper`
/// precedent).
///
/// # Namespacing
///
/// The registered name is `pack_<id>_<action>` with the pack id's dots flattened — e.g.
/// `pack_com_example_barista_dial_in_shot`. The plan sketched `pack:<id>/<action>`, but LLM
/// function names must satisfy `[a-zA-Z0-9_.-]`-style charsets on both provider wires, so the
/// namespace is spelled in underscores. The property it exists for holds either way: a pack tool
/// can never shadow a native tool, because every pack tool name begins with `pack_` and the
/// validator refuses native-name reuse in the raw action name too.
struct SkillPackToolWrapper: NativeTool {

    let packId: String
    let action: SkillPackAction
    /// The pack's declared settings, so `{{setting.key}}` substitutions resolve the user's
    /// configured values (P2).
    var settingDeclarations: [SkillPackManifest.SettingDeclaration] = []
    /// Resolves a native tool for `.tool` bindings. Injected; never captures the registry (the
    /// wrapper is *in* the registry — a strong loop there would leak both).
    let resolveNativeTool: @MainActor (String) -> (any NativeTool)?

    private var settingsValues: [String: String] {
        SkillPackSettings.values(packId: packId, declarations: settingDeclarations)
    }

    static func toolName(packId: String, actionName: String) -> String {
        "pack_" + packId.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
            + "_" + actionName
    }

    var name: String { Self.toolName(packId: packId, actionName: action.name) }

    var description: String {
        // The pack's own description, attributed — the model should know this capability came
        // from an installed pack when deciding whether to trust its instructions.
        "\(action.description) (from installed skill pack '\(packId)')"
    }

    var parametersSchema: [String: Any] {
        let schema = action.parametersSchema
        return schema.isEmpty ? ["type": "object", "properties": [String: Any]()] : schema
    }

    func execute(args: [String: Any]) async throws -> String {
        switch action.binding {
        case .prompt(let template):
            // A canned instruction through the normal turn. Pack text is untrusted input, so it
            // rides inside the Plan R envelope — the router skips framing for registry tools
            // (isKnownNativeTool), which is exactly right for real native tools and exactly wrong
            // for pack content, so the wrapper frames its own output.
            let filled = Self.substitute(template: template, args: args, settings: settingsValues)
            return PromptInjectionPolicy.wrap(toolName: name, content: filled)

        case .tool(let target, let boundArgs):
            guard let tool = resolveNativeTool(target) else {
                return "This skill's underlying tool '\(target)' isn't available on this device."
            }
            // Bound args are templates over the caller's args; caller args pass through
            // underneath, bound keys win — the pack author's contract, not the model's.
            // Substitution yields strings, but native tools type-check their args (`as? Int`),
            // so a purely numeric/boolean result is coerced — without this, a `tool` binding
            // could never satisfy a required integer parameter like set_timer's `seconds`
            // (found authoring the first real pack, not in review).
            var merged = args
            for (key, template) in boundArgs {
                let substituted = Self.substitute(template: template, args: args, settings: settingsValues)
                merged[key] = Self.coerce(substituted)
            }
            return try await tool.execute(args: merged)

        case .procedure(let id):
            // Parsed and validated in P1; runnable when P2 lands the content pipeline.
            return "This skill starts procedure '\(id)', which isn't supported in this build yet."

        case .gateway(let task):
            // Standing rule: gateway/autonomous features are inert without Agent Mode.
            guard Config.agentModeEnabled else {
                return "This skill delegates to the remote agent, and Agent Mode is off. Enable Agent Mode in Settings to use it."
            }
            let filled = Self.substitute(template: task, args: args, settings: settingsValues)
            guard let bridge = AppStateProvider.shared?.openClawBridge else {
                return "The remote agent isn't available right now."
            }
            let result = await bridge.delegateTask(task: filled, toolName: name)
            switch result {
            case .success(let text): return PromptInjectionPolicy.wrap(toolName: name, content: text)
            case .failure(let error): return "Skill delegation failed: \(error)"
            }
        }
    }

    /// A fully numeric or boolean substitution result becomes the typed value; anything else
    /// stays a string. Deliberately conservative — "300" coerces, "300s" does not.
    static func coerce(_ value: String) -> Any {
        if let int = Int(value) { return int }
        if let double = Double(value) { return double }
        if value == "true" { return true }
        if value == "false" { return false }
        return value
    }

    /// `{{param}}` → the argument's string form, `{{setting.key}}` → the user's configured value
    /// for this pack (Plan BX P2 settings-as-schema). Unmatched placeholders stay visible rather
    /// than silently vanishing, so a template/schema mismatch is diagnosable from the transcript.
    static func substitute(template: String, args: [String: Any], settings: [String: String] = [:]) -> String {
        var out = template
        for (key, value) in args {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: "\(value)")
        }
        for (key, value) in settings {
            out = out.replacingOccurrences(of: "{{setting.\(key)}}", with: value)
        }
        return out
    }
}

extension NativeToolRegistry {

    /// Merge every enabled pack's actions into the registry (Plan BX P1). Call after both the
    /// registry and the store exist; re-call after install/remove/enable changes — the previous
    /// merge is removed first, so this is a rebuild, and a pack that left the store leaves the
    /// registry with it.
    func registerSkillPackTools(from store: SkillPackStore) {
        removeSkillPackTools()
        for manifest in store.activeManifests() {
            for action in manifest.actions {
                register(SkillPackToolWrapper(
                    packId: manifest.id,
                    action: action,
                    settingDeclarations: manifest.settings,
                    resolveNativeTool: { [weak self] target in
                        guard let self else { return nil }
                        // .tool bindings compose over native tools only — resolving another
                        // pack's wrapper here would enable pack chaining, which v1 refuses.
                        guard let tool = self.tool(named: target), !(tool is SkillPackToolWrapper) else {
                            return nil
                        }
                        return tool
                    }))
            }
        }
    }
}
