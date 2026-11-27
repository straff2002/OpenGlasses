import Foundation

// Plan LW §1 — a new vault from a name, a trade template and (optionally) its models: a manifest and
// the core files the vault guide describes, ready to install as a user-imported vault. It works from
// the first manual added, because manual retrieval answers from the manuals alone.
//
// Foundation only, self-contained with `TradeTemplate.swift` and `VaultDrafts.swift` (see there).
// Deterministic: the same input gives the same bytes, so the phone and the portal cannot drift.
// What it writes passes `VaultPackRules.manifestIssues` and `listedFileIssue` for a vault that is not
// manual-only (`VaultStarterTests`).

public enum VaultStarter {

    /// A model the vault is for, and the other ways the manuals and nameplates spell it.
    public struct Model: Equatable, Sendable {
        public let name: String
        public let aliases: [String]

        public init(_ name: String, aliases: [String] = []) {
            self.name = name
            self.aliases = aliases
        }
    }

    public struct File: Equatable, Sendable {
        public let name: String
        public let contents: String
    }

    public struct Output: Equatable, Sendable {
        public let id: String
        public let name: String
        /// `manifest.json`'s bytes: sorted keys, pretty-printed, slashes unescaped.
        public let manifestJSON: Data
        /// The core files, in the manifest's `files` order.
        public let files: [File]
    }

    public enum Failure: Error, Equatable {
        /// The vault's name is empty once trimmed.
        case emptyName
    }

    public static let safetyFile = "safety.md"
    public static let modelsFile = "models.md"
    public static let faultCodesFile = "fault-codes.md"
    public static let symptomsFile = "symptoms.md"
    /// The core files a starter lists, in prompt order.
    public static let fileNames = [safetyFile, modelsFile, faultCodesFile, symptomsFile]
    public static let documentsDirectory = "documents"
    /// A vault of the subscriber's own: the gating every custom vault carries (vault guide, Step 3).
    public static let gating = "enterprise"
    public static let version = "1.0.0"
    /// The header row the fault-code tables use; `IndexRowWriter.faultCodeLine` writes rows under it.
    public static let faultCodeTableHeader = "| Code | Meaning | Manual and page |\n|------|---------|-----------------|"

    /// The starter vault. `id` defaults to `vaultId(forName:)`; the phone passes one of its own when
    /// that id is already installed.
    public static func make(name: String, template: TradeTemplate, models: [Model] = [],
                            id: String? = nil) throws -> Output {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        let vaultName = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        let vaultId = id ?? vaultId(forName: vaultName)

        let files = [
            File(name: safetyFile, contents: template.safetyStarter),
            File(name: modelsFile, contents: modelsMarkdown(normalised(models))),
            File(name: faultCodesFile, contents: faultCodesMarkdown(template)),
            File(name: symptomsFile, contents: symptomsMarkdown(template))
        ]
        let manifest = Manifest(id: vaultId, name: vaultName, version: version, files: fileNames,
                                documentsDir: documentsDirectory, documents: [], gating: .init(iap: gating),
                                promptRules: template.promptRules, sourceAttributionFormat: "Source: {files}",
                                sourceAttributionRequired: true, trades: template.trades)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return Output(id: vaultId, name: vaultName, manifestJSON: try encoder.encode(manifest), files: files)
    }

    /// A manifest id from a vault's name: lowercase ASCII letters and digits, everything else one
    /// underscore, at most 64 characters (the vault guide: "lowercase, no spaces"). A name with no
    /// ASCII letter or digit gives `my_vault`.
    public static func vaultId(forName name: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                if pendingSeparator && !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        let capped = String(out.prefix(64))
        let trimmed = capped.hasSuffix("_") ? String(capped.dropLast()) : capped
        return trimmed.isEmpty ? "my_vault" : trimmed
    }

    // MARK: - The files

    /// One `## MODEL (alias, alias)` heading per model, as `VaultModelIndex` reads them, with a line
    /// under each for the manuals that cover it.
    static func modelsMarkdown(_ models: [Model]) -> String {
        var lines = [
            "# Models",
            "",
            "One section per model. Put every spelling of the model in its heading, the other spellings in brackets. Under it, list the manuals that cover it, by key and page.",
            ""
        ]
        for model in models {
            let heading = model.aliases.isEmpty ? model.name : "\(model.name) (\(model.aliases.joined(separator: ", ")))"
            lines.append("## \(heading)")
            lines.append("Manuals: none yet.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func faultCodesMarkdown(_ template: TradeTemplate) -> String {
        var lines = [
            "# Fault codes",
            "",
            "Each row: the code as the display shows it, what it means in a few words of your own, and the manual key and page that say so.",
            ""
        ]
        for section in template.faultCodeSections {
            lines.append("## \(section)")
            lines.append("")
            lines.append(faultCodeTableHeader)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func symptomsMarkdown(_ template: TradeTemplate) -> String {
        var lines = [
            "# Symptoms",
            "",
            "One section per symptom, in your technicians' words. Under each: what they say, which models it applies to, and the checks in order, each with a manual key and page. Leave a section empty until you have checked its pages.",
            ""
        ]
        for heading in template.symptomHeadings {
            lines.append("## \(heading)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Models with their names and aliases trimmed, characters a heading cannot carry taken out
    /// (brackets, `#`, line breaks), empty ones dropped, and spellings de-duplicated case-insensitively:
    /// a model named twice keeps one heading with both lists of aliases.
    static func normalised(_ models: [Model]) -> [Model] {
        func clean(_ text: String) -> String {
            let banned = CharacterSet(charactersIn: "()[]#,").union(.newlines)
            return text.components(separatedBy: banned).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var order: [String] = []
        var byKey: [String: (name: String, aliases: [String])] = [:]
        for model in models {
            let name = clean(model.name)
            guard !name.isEmpty else { continue }
            let key = name.uppercased()
            if byKey[key] == nil { order.append(key); byKey[key] = (name, []) }
            for alias in model.aliases.map(clean) where !alias.isEmpty {
                var entry = byKey[key]!
                let taken = Set(([entry.name] + entry.aliases).map { $0.uppercased() })
                if !taken.contains(alias.uppercased()) { entry.aliases.append(alias); byKey[key] = entry }
            }
        }
        // A spelling that is another model's own name stays that model's: it is not an alias here.
        let names = Set(order)
        return order.map { key in
            let entry = byKey[key]!
            return Model(entry.name, aliases: entry.aliases.filter { !names.contains($0.uppercased()) })
        }
    }

    // MARK: - The manifest

    /// The manifest's keys as the app's `VaultManifest` and the vault guide spell them.
    struct Manifest: Encodable {
        struct Gating: Encodable { let iap: String }
        let id: String
        let name: String
        let version: String
        let files: [String]
        let documentsDir: String
        let documents: [String]
        let gating: Gating
        let promptRules: [String]
        let sourceAttributionFormat: String
        let sourceAttributionRequired: Bool
        let trades: [String]?
        /// The closed equipment-type list (`equipment_types`); absent when nil.
        var equipmentTypes: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case id, name, version, files, documents, gating, trades
            case equipmentTypes = "equipment_types"
            case documentsDir = "documents_dir"
            case promptRules = "prompt_rules"
            case sourceAttributionFormat = "source_attribution_format"
            case sourceAttributionRequired = "source_attribution_required"
        }
    }
}
