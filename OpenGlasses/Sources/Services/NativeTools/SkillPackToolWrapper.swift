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
    /// Hands a resolved child call to the one execution authority. Injected as a closure rather
    /// than a reference so the wrapper never captures the registry or the router (the wrapper is
    /// *in* the registry — a strong loop there would leak both).
    ///
    /// The wrapper does template substitution and type coercion and nothing else: it holds no tool
    /// instance and has no way to execute one. The default fails closed, so a wrapper built without
    /// an authority refuses instead of finding another route.
    var dispatchChild: @MainActor (ResolvedToolCall) async -> ToolResult = { call in
        .failure(ComposedToolPolicy.unroutedRefusal(target: call.name))
    }

    /// Every wrapper's registered name begins with this, which is what makes a pack tool unable to
    /// shadow a native one — and what lets the authority spot pack-to-pack chaining.
    static let namePrefix = "pack_"

    private var settingsValues: [String: String] {
        SkillPackSettings.values(packId: packId, declarations: settingDeclarations)
    }

    static func toolName(packId: String, actionName: String) -> String {
        namePrefix + packId.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
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
            // Bound args are templates over the caller's args; caller args pass through
            // underneath, bound keys win — the pack author's contract, not the model's.
            // Substitution yields strings, but native tools type-check their args (`as? Int`),
            // so a purely numeric/boolean result is coerced — without this, a `tool` binding
            // could never satisfy a required integer parameter like set_timer's `seconds`
            // (found authoring the first real pack, not in review).
            var merged = ToolArguments(args)
            for (key, template) in boundArgs {
                let substituted = Self.substitute(template: template, args: args, settings: settingsValues)
                merged.set(key, to: Self.coerce(substituted))
            }
            // The full child call — real target, final merged arguments — is resolved *before* any
            // safety decision, then handed to the authority. Nothing here can execute it.
            let parent = ToolInvocationScope.current
                ?? .root(name: name, arguments: ToolArguments(args), origin: .skillPack)
            let child = parent.child(name: target, arguments: merged, composerID: packId,
                                     origin: .skillPack)
            switch await dispatchChild(child) {
            case .success(let text): return text
            case .failure(let message): return message
            }

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
    /// `authority` is what a `.tool` binding's child call is dispatched to. Without one (or once it
    /// goes away) a merged pack's prompt bindings keep working and its composed bindings refuse —
    /// composition with no authorization boundary is not a supported mode.
    func registerSkillPackTools(from store: SkillPackStore,
                                authority: (any ToolExecutionAuthority)? = nil) {
        removeSkillPackTools()
        for manifest in store.activeManifests() {
            // Re-run the composition floor over what's actually installed: a pack admitted by an
            // earlier build can hold a `.tool` binding the floor now forbids. The pack stays
            // installed and its other actions register; only the offending ones are held back,
            // with the reason recorded on the row for the Settings UI.
            let quarantined = SkillPackValidator.restrictedActionNames(in: manifest)
            store.setQuarantinedActions(quarantined, id: manifest.id)
            for action in manifest.actions where !quarantined.contains(action.name) {
                register(SkillPackToolWrapper(
                    packId: manifest.id,
                    action: action,
                    settingDeclarations: manifest.settings,
                    dispatchChild: { [weak authority] call in
                        guard let authority else {
                            return .failure(ComposedToolPolicy.unroutedRefusal(target: call.name))
                        }
                        return await authority.execute(call)
                    }))
            }
        }
    }
}
