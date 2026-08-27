import Foundation

/// Plan BX P1 — admission control for a decoded skill pack.
///
/// Pack-supplied text is untrusted input: every action description runs through the Plan R
/// poisoning screen (`ToolDefinitionScanner`) here, at install — the same screen MCP tools pass —
/// and a blocked action rejects the pack rather than quietly shipping a poisoned description into
/// the system prompt.
enum SkillPackValidator {

    /// Caps: a pack is content, not a data dump. Oversize is a rejection, not a truncation.
    static let maxActions = 32
    static let maxSettings = 64
    static let maxDescriptionLength = 1_000
    static let maxTemplateLength = 8_000

    enum Outcome: Equatable {
        case accepted(warnings: [String])
        case rejected(reasons: [String])

        var isAccepted: Bool { if case .accepted = self { return true }; return false }
    }

    /// Validate a manifest (post-`lossyDecode`) for installation.
    ///
    /// - Parameters:
    ///   - report: the decode report; a lossy decode is a *warning* (the good actions install, the
    ///     row says what was dropped), never silently clean.
    ///   - currentBuild: the running app build, for `minAppBuild` gating.
    ///   - nativeToolNames: raw native tool names — a pack action may not share one even though
    ///     the registered name is namespaced, so confusion can't be engineered in the prompt.
    static func validate(
        manifest: SkillPackManifest,
        report: SkillPackDecodeReport,
        currentBuild: Int,
        nativeToolNames: Set<String>
    ) -> Outcome {
        var reasons: [String] = []
        var warnings: [String] = []

        // Identity: reverse-DNS id and semver, both because they name filesystem locations and
        // upgrade ordering — garbage here corrupts the store layout, not just cosmetics.
        if !isReverseDNS(manifest.id) {
            reasons.append("pack id '\(manifest.id)' is not reverse-DNS (e.g. com.example.pack)")
        }
        if !isSemver(manifest.version) {
            reasons.append("version '\(manifest.version)' is not semver (e.g. 1.2.0)")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("pack name is empty")
        }

        if let minBuild = manifest.minAppBuild, minBuild > currentBuild {
            reasons.append("requires app build \(minBuild); this is \(currentBuild)")
        }

        if manifest.actions.count > maxActions {
            reasons.append("\(manifest.actions.count) actions exceeds the cap of \(maxActions)")
        }
        if manifest.settings.count > maxSettings {
            reasons.append("\(manifest.settings.count) settings exceeds the cap of \(maxSettings)")
        }

        var seenNames = Set<String>()
        for action in manifest.actions {
            reasons.append(contentsOf: validate(action: action, nativeToolNames: nativeToolNames,
                                                seenNames: &seenNames))
        }

        if !report.isClean {
            warnings.append("partial load — \(report.summary)")
        }

        return reasons.isEmpty ? .accepted(warnings: warnings) : .rejected(reasons: reasons)
    }

    private static func validate(
        action: SkillPackAction,
        nativeToolNames: Set<String>,
        seenNames: inout Set<String>
    ) -> [String] {
        var reasons: [String] = []
        let name = action.name

        if !isActionName(name) {
            reasons.append("action '\(name)' is not a lowercase identifier (a-z, 0-9, _)")
        }
        if !seenNames.insert(name).inserted {
            reasons.append("duplicate action name '\(name)'")
        }
        // The registered name is namespaced so a pack can never *shadow* a native tool — this
        // check exists for the prompt, where a same-named action invites the model to confuse
        // the two.
        if nativeToolNames.contains(name) {
            reasons.append("action '\(name)' shares a native tool's name")
        }
        if action.description.count > maxDescriptionLength {
            reasons.append("action '\(name)' description exceeds \(maxDescriptionLength) chars")
        }

        // Parameters must be a JSON-Schema *object* — that's the shape every declaration path
        // (native, MCP, Gemini translation) assumes.
        let schema = action.parametersSchema
        if !schema.isEmpty, (schema["type"] as? String) != "object" {
            reasons.append("action '\(name)' parameters schema must have type 'object'")
        }

        switch action.binding {
        case .prompt(let template):
            if template.count > maxTemplateLength {
                reasons.append("action '\(name)' template exceeds \(maxTemplateLength) chars")
            }
            if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("action '\(name)' has an empty prompt template")
            }
        case .tool(let target, _):
            // Bind only to real native tools, never to another pack's namespaced tool — pack
            // chaining is complexity with no v1 use case and a real audit cost.
            if !nativeToolNames.contains(target) {
                reasons.append("action '\(name)' binds to unknown native tool '\(target)'")
            }
            // A wrapper executes its target directly, so the router's confirmation gate never
            // sees the real name. Anything that gate would have caught is refused at the door.
            if ComposedToolPolicy.isRestrictedTarget(target) {
                reasons.append("action '\(name)' \(ComposedToolPolicy.admissionReason(target: target))")
            }
        case .procedure(let id):
            if id.isEmpty { reasons.append("action '\(name)' has an empty procedure id") }
        case .gateway(let task):
            if task.isEmpty { reasons.append("action '\(name)' has an empty gateway task") }
        }

        // Plan R poisoning screen over the pack-supplied description. For MCP tools a quarantine
        // is a runtime posture (qualified name + badge); for a pack, install IS the trust
        // decision, so anything the scanner flags — blocked or quarantined — refuses the pack at
        // the door. Scanned with the *effective* schema (a no-parameter action registers as an
        // empty object schema), so "missing schema" can't false-positive a legitimate
        // parameterless prompt action.
        let effectiveSchema: [String: Any] = schema.isEmpty
            ? ["type": "object", "properties": [String: Any]()]
            : schema
        let trust = ToolDefinitionScanner.scan(
            name: name,
            description: action.description,
            inputSchema: effectiveSchema,
            nativeNames: [])   // native collision is already a rejection above, with a clearer message
        switch trust {
        case .trusted:
            break
        case .blocked(let why), .quarantined(let why):
            reasons.append("action '\(name)' failed the definition screen: \(why)")
        }

        return reasons
    }

    /// Names of an installed pack's actions whose `.tool` target the composition floor forbids.
    ///
    /// Packs installed by an earlier build predate that floor, so the registry merge re-runs this
    /// on every launch and refresh rather than trusting install-time admission. Pure so the
    /// reclassification is asserted without a store or a registry.
    static func restrictedActionNames(in manifest: SkillPackManifest) -> [String] {
        manifest.actions.compactMap { action in
            guard case .tool(let target, _) = action.binding,
                  ComposedToolPolicy.isRestrictedTarget(target) else { return nil }
            return action.name
        }
    }

    // MARK: - Shapes

    static func isReverseDNS(_ id: String) -> Bool {
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    static func isSemver(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func isActionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, let first = name.first,
              first.isLetter || first == "_" else { return false }
        return name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "_" }
    }
}
