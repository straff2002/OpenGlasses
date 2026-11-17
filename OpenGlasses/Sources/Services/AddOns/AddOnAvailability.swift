import Foundation
import CryptoKit

/// The name an add-on skill is offered to the model under.
///
/// `addon_<id>_<skill>`, with every character of the id that is not an ASCII letter or digit
/// written `_` (`RecipeRunner.toolName`). Provider function names are capped at 64 characters, so
/// a longer name keeps the start of the id, adds six hex digits of the id's SHA-256 (so two long
/// ids that share a start still differ) and the whole skill name. Every name starts `addon_`, which
/// is what makes an add-on unable to shadow a native tool and what the composition floor refuses
/// to chain into.
enum AddOnToolNaming {

    static let prefix = "addon_"
    static let maxLength = 64

    static func toolName(addOnID: String, skill: String) -> String {
        let plain = RecipeRunner.toolName(addOnID: addOnID, skill: skill)
        guard plain.count > maxLength else { return plain }
        let flat = String(addOnID.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        let digest = SHA256.hash(data: Data(addOnID.utf8)).map { String(format: "%02x", $0) }.joined()
        let tag = String(digest.prefix(6))
        // prefix + idStart + "_" + tag + "_" + skill
        let room = maxLength - prefix.count - 1 - tag.count - 1 - skill.count
        let start = String(flat.prefix(max(0, room)))
        let name = prefix + (start.isEmpty ? "" : start + "_") + tag + "_" + skill
        return String(name.prefix(maxLength))
    }
}

/// Whether an installed add-on's skills are offered to the model right now, and if not, why.
///
/// Pure over `Conditions`, so the registry, the Settings rows and the tests read one rule:
/// - the add-ons switch (`Config.addOnsEnabled`) and the add-on's own switch;
/// - the organisation's policy (`AddOnPolicy`), which may refuse a trust class or the feature;
/// - Medical Compliance: an add-on with `network` is not declared while it is on (decision 5), so
///   nothing from a transcript leaves through one — Local Only binds only inside Medical
///   Compliance, so it is covered by the same rule, and the request edge refuses the route too
///   (`MedicalEgressGuard`, `NetworkRoute.recipeAddOn`);
/// - coverage: outside the regions an add-on lists, its skills are not declared. An unknown region
///   does not hide it — "outside" has to be known.
enum AddOnAvailability {

    enum Hidden: Equatable, Sendable {
        case addOnsOff
        case turnedOff
        case policy(AddOnPolicy.Refusal)
        case medicalCompliance
        case outsideCoverage
    }

    struct Conditions: Equatable, Sendable {
        var addOnsEnabled: Bool = true
        /// Medical Compliance. Its Local Only setting binds only while this is on
        /// (`MedicalEgressGuard.Mode.isEnforcing`), so this one flag covers both.
        var hipaaMode: Bool = false
        /// ISO 3166-1 alpha-2, uppercase; nil when the phone's region is unknown.
        var region: String?
        var policy: AddOnPolicy = .unmanaged
    }

    static func hidden(_ manifest: RecipeAddOnManifest, trust: AddOnTrustClass, enabled: Bool,
                       conditions: Conditions) -> Hidden? {
        guard conditions.addOnsEnabled else { return .addOnsOff }
        if let refusal = conditions.policy.refusal(for: trust) { return .policy(refusal) }
        guard enabled else { return .turnedOff }
        if usesNetwork(manifest), conditions.hipaaMode {
            return .medicalCompliance
        }
        if !isCovered(manifest.coverage, region: conditions.region) { return .outsideCoverage }
        return nil
    }

    /// An add-on that can reach a host: any `network` entry, or an MCP entry.
    static func usesNetwork(_ manifest: RecipeAddOnManifest) -> Bool {
        !manifest.permissions.network.isEmpty || manifest.mcp != nil
    }

    static func isCovered(_ coverage: [String]?, region: String?) -> Bool {
        guard let coverage, !coverage.isEmpty, !coverage.contains("*") else { return true }
        guard let region = region?.uppercased(), !region.isEmpty else { return true }
        return coverage.contains { $0.uppercased() == region }
    }

    /// The line a Settings row shows for a hidden add-on.
    static func explanation(_ hidden: Hidden) -> String {
        switch hidden {
        case .addOnsOff: return String(localized: "Add-ons are off")
        case .turnedOff: return String(localized: "Off")
        case .policy(let refusal): return AddOnAdmission.message(for: refusal)
        case .medicalCompliance: return String(localized: "Not available while Medical Compliance is on, because it connects to the internet")
        case .outsideCoverage: return String(localized: "Not available in your region")
        }
    }
}
