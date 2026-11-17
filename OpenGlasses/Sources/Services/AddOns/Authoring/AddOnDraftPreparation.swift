import Foundation

/// Turns the model's add-on object into the file the wearer is shown: the app's own identity
/// fields written in, the permissions recomputed by `PermissionMinimizer`, and the result checked
/// by the same validator every add-on passes. Pure.
enum AddOnDraftPreparation {

    struct Identity: Equatable, Sendable {
        let id: String
        let version: String
        let authorWeb: String?
    }

    struct Prepared: Equatable, Sendable {
        /// The exact file: what is tested, shown, stored and exported.
        let fileBytes: Data
        let manifest: RecipeAddOnManifest
        let minimised: PermissionMinimizer.Outcome
    }

    enum Problem: Error, Equatable, Sendable {
        case notAnObject
        case minimiser(PermissionMinimizer.Refusal)
        case invalid([String])
        case sampleSkillMissing(String)

        /// Lines for the repair prompt.
        var repairLines: [String] {
            switch self {
            case .notAnObject: return ["the add-on must be one JSON object"]
            case .minimiser(let refusal): return [refusal.detail]
            case .invalid(let lines): return lines
            case .sampleSkillMissing(let skill): return ["the sample names \"\(skill)\", which is not one of the add-on's skills"]
            }
        }
    }

    /// The model's name for the add-on, read before anything else so the id can be made from it.
    static func proposedName(_ addOn: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: addOn)) as? [String: Any])?["name"] as? String
    }

    static func prepare(_ addOn: Data, identity: Identity, sample: AddOnAuthoringPrompt.Sample,
                        nativeToolNames: Set<String>) -> Result<Prepared, Problem> {
        guard var object = (try? JSONSerialization.jsonObject(with: addOn)) as? [String: Any] else {
            return .failure(.notAnObject)
        }
        // The app's fields, whatever the model wrote; nothing a self-built file may not carry.
        object["format"] = RecipeAddOnManifest.formatTag
        object["id"] = identity.id
        object["version"] = identity.version
        var author: [String: Any] = ["name": SelfBuiltIdentity.authorName]
        if let web = identity.authorWeb { author["web"] = web }
        object["author"] = author
        object.removeValue(forKey: "minAppBuild")
        object.removeValue(forKey: "mcp")
        let declared = object["permissions"]
        // Decode once with the declared permissions read loosely, so a misspelt permission is
        // simply dropped rather than refusing the whole draft: the minimiser decides them anyway.
        object["permissions"] = looselyRead(declared)

        guard let firstPass = serialise(object) else { return .failure(.notAnObject) }
        let manifest: RecipeAddOnManifest
        do {
            manifest = try RecipeAddOnManifest.decode(firstPass)
        } catch let error as RecipeAddOnDecodeError {
            return .failure(.invalid([error.message]))
        } catch {
            return .failure(.notAnObject)
        }
        let minimised: PermissionMinimizer.Outcome
        switch PermissionMinimizer.minimise(manifest) {
        case .failure(let refusal): return .failure(.minimiser(refusal))
        case .success(let outcome): minimised = outcome
        }
        object["permissions"] = PermissionMinimizer.jsonObject(minimised.permissions)
        guard let bytes = serialise(object) else { return .failure(.notAnObject) }

        let report = RecipeAddOnValidator.validate(data: bytes, nativeToolNames: nativeToolNames, trust: .community)
        guard let final = report.manifest, report.issues.isEmpty else {
            return .failure(.invalid(report.issues.map(\.description)))
        }
        guard final.skills.contains(where: { $0.name == sample.skill }) else {
            return .failure(.sampleSkillMissing(sample.skill))
        }
        return .success(Prepared(fileBytes: bytes, manifest: final, minimised: minimised))
    }

    /// Pretty, with sorted keys: the source view shows it as written.
    static func serialise(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object,
                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Only the four permission keys, each only if it has the right type.
    private static func looselyRead(_ raw: Any?) -> [String: Any] {
        guard let raw = raw as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        if let network = raw["network"] as? [String] { out["network"] = network }
        for key in ["location", "memory", "display"] {
            if let flag = raw[key] as? Bool { out[key] = flag }
        }
        return out
    }
}
