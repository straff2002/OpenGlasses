import Foundation

/// Plan BX P1 — the skill-pack manifest: the unit of installable, data-driven capability.
///
/// A pack is a signed bundle of *content* — LLM-callable actions, prompts, procedures, settings —
/// never executable code. Actions merge into `NativeToolRegistry` behind a namespaced wrapper and
/// flow into both prompt builders through the existing `SystemPromptBuilder` path.
struct SkillPackManifest: Codable, Equatable {
    let id: String              // reverse-DNS, e.g. "com.example.barista"
    let version: String         // semver
    let name: String
    let summary: String
    /// Minimum app build this pack needs (nil = any).
    let minAppBuild: Int?
    let hardware: [HardwareRequirement]
    let actions: [SkillPackAction]
    let settings: [SettingDeclaration]

    init(id: String, version: String, name: String, summary: String, minAppBuild: Int? = nil,
         hardware: [HardwareRequirement] = [], actions: [SkillPackAction] = [],
         settings: [SettingDeclaration] = []) {
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.minAppBuild = minAppBuild
        self.hardware = hardware
        self.actions = actions
        self.settings = settings
    }

    // Optional collections decode as empty rather than failing the whole manifest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        minAppBuild = try c.decodeIfPresent(Int.self, forKey: .minAppBuild)
        hardware = try c.decodeIfPresent([HardwareRequirement].self, forKey: .hardware) ?? []
        actions = try c.decodeIfPresent([SkillPackAction].self, forKey: .actions) ?? []
        settings = try c.decodeIfPresent([SettingDeclaration].self, forKey: .settings) ?? []
    }

    struct HardwareRequirement: Codable, Equatable {
        enum Kind: String, Codable { case camera, display }
        enum Level: String, Codable { case required, optional }
        let type: Kind
        let level: Level
    }

    /// A typed settings declaration the host renders — no per-pack UI (BX "settings-as-schema").
    struct SettingDeclaration: Codable, Equatable {
        let key: String
        let type: String            // "toggle" | "select" | "text" | "number"
        let label: String?
        let options: [String]?      // for "select"
    }
}

/// One LLM-callable action. `parameters` is a JSON-Schema object with an LLM-oriented
/// description — the same shape native tools declare.
struct SkillPackAction: Codable, Equatable {
    let name: String
    let description: String
    /// JSON-Schema for the arguments, kept as raw JSON so it passes through to the tool
    /// declaration untouched.
    let parametersJSON: Data
    let binding: SkillPackBinding

    var parametersSchema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: parametersJSON) as? [String: Any]) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case name, description, parameters, binding }

    init(name: String, description: String, parametersSchema: [String: Any], binding: SkillPackBinding) {
        self.name = name
        self.description = description
        self.parametersJSON = (try? JSONSerialization.data(withJSONObject: parametersSchema, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.binding = binding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        binding = try c.decode(SkillPackBinding.self, forKey: .binding)
        if let raw = try c.decodeIfPresent(AnyCodable.self, forKey: .parameters),
           let dict = raw.value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            parametersJSON = data
        } else {
            parametersJSON = Data("{}".utf8)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(binding, forKey: .binding)
        if let obj = try? JSONSerialization.jsonObject(with: parametersJSON) {
            try c.encode(AnyCodable(obj), forKey: .parameters)
        }
    }

    static func == (lhs: SkillPackAction, rhs: SkillPackAction) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
            && lhs.parametersJSON == rhs.parametersJSON && lhs.binding == rhs.binding
    }
}

/// What an action does when called. **No arbitrary code in v1** — a future `js` kind
/// (JavaScriptCore, headless, per-pack context) is Plan BX P4; the enum is where that seam lives,
/// and an unknown kind is a per-action decode failure the lossy report surfaces, not a crash.
enum SkillPackBinding: Codable, Equatable {
    /// A canned instruction through the normal assistant turn. `{{param}}` placeholders are
    /// substituted from the call arguments.
    case prompt(template: String)
    /// Composition over an existing native tool, with bound argument templates merged over the
    /// caller's arguments.
    case tool(name: String, boundArgs: [String: String])
    /// Starts a pack-supplied or existing procedure. Parsed in P1; execution lands with P2's
    /// content pipeline.
    case procedure(id: String)
    /// Delegate to the remote agent. **Inert without Agent Mode** — refused at execution, per the
    /// standing rule for gateway/autonomous features.
    case gateway(task: String)

    enum CodingKeys: String, CodingKey { case kind, template, name, boundArgs, id, task }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "prompt":
            self = .prompt(template: try c.decode(String.self, forKey: .template))
        case "tool":
            self = .tool(name: try c.decode(String.self, forKey: .name),
                         boundArgs: try c.decodeIfPresent([String: String].self, forKey: .boundArgs) ?? [:])
        case "procedure":
            self = .procedure(id: try c.decode(String.self, forKey: .id))
        case "gateway":
            self = .gateway(task: try c.decode(String.self, forKey: .task))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown binding kind '\(kind)' — supported: prompt, tool, procedure, gateway")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prompt(let template):
            try c.encode("prompt", forKey: .kind)
            try c.encode(template, forKey: .template)
        case .tool(let name, let boundArgs):
            try c.encode("tool", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(boundArgs, forKey: .boundArgs)
        case .procedure(let id):
            try c.encode("procedure", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .gateway(let task):
            try c.encode("gateway", forKey: .kind)
            try c.encode(task, forKey: .task)
        }
    }
}

/// What was dropped while decoding a manifest, and why (Plan BB lesson: never silent-drop).
/// A pack with one bad action loads the rest and *says so* — in the log, the install result, and
/// eventually the Settings row.
struct SkillPackDecodeReport: Equatable {
    struct DroppedAction: Equatable {
        let index: Int
        /// The action's name when it could be read, so the report is actionable.
        let name: String?
        let reason: String
    }
    var droppedActions: [DroppedAction] = []
    var droppedSettings: Int = 0

    var isClean: Bool { droppedActions.isEmpty && droppedSettings == 0 }

    var summary: String {
        guard !isClean else { return "clean" }
        var parts: [String] = []
        if !droppedActions.isEmpty {
            let names = droppedActions.map { $0.name ?? "#\($0.index)" }.joined(separator: ", ")
            parts.append("\(droppedActions.count) action(s) dropped: \(names)")
        }
        if droppedSettings > 0 { parts.append("\(droppedSettings) setting(s) dropped") }
        return parts.joined(separator: "; ")
    }
}

extension SkillPackManifest {

    /// Decode keeping everything decodable: a malformed action or setting is dropped **and
    /// reported** rather than failing the manifest (or vanishing). Returns `nil` manifest only
    /// when the pack's identity itself (id/version/name) can't be read — there is nothing safe to
    /// partially load at that point.
    static func lossyDecode(_ data: Data) -> (manifest: SkillPackManifest?, report: SkillPackDecodeReport) {
        var report = SkillPackDecodeReport()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["id"] as? String,
              let version = root["version"] as? String,
              let name = root["name"] as? String else {
            return (nil, report)
        }

        let decoder = JSONDecoder()

        var actions: [SkillPackAction] = []
        for (index, element) in ((root["actions"] as? [Any]) ?? []).enumerated() {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else {
                report.droppedActions.append(.init(index: index, name: nil, reason: "not a JSON object"))
                continue
            }
            do {
                actions.append(try decoder.decode(SkillPackAction.self, from: elementData))
            } catch {
                let actionName = (element as? [String: Any])?["name"] as? String
                report.droppedActions.append(.init(index: index, name: actionName,
                                                   reason: shortDecodeError(error)))
            }
        }

        var settings: [SettingDeclaration] = []
        for element in ((root["settings"] as? [Any]) ?? []) {
            if let elementData = try? JSONSerialization.data(withJSONObject: element),
               let decoded = try? decoder.decode(SettingDeclaration.self, from: elementData) {
                settings.append(decoded)
            } else {
                report.droppedSettings += 1
            }
        }

        let hardware: [HardwareRequirement] = ((root["hardware"] as? [Any]) ?? []).compactMap {
            guard let d = try? JSONSerialization.data(withJSONObject: $0) else { return nil }
            return try? decoder.decode(HardwareRequirement.self, from: d)
        }

        let manifest = SkillPackManifest(
            id: id,
            version: version,
            name: name,
            summary: root["summary"] as? String ?? "",
            minAppBuild: root["minAppBuild"] as? Int,
            hardware: hardware,
            actions: actions,
            settings: settings)
        return (manifest, report)
    }

    private static func shortDecodeError(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error { return ctx.debugDescription }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing '\(key.stringValue)'" }
        if case DecodingError.typeMismatch(_, let ctx) = error {
            return "type mismatch at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        }
        return error.localizedDescription
    }
}
