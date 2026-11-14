import Foundation

// Plan LR — the structural rules a vault pack is held to, in one place for both sides: the phone
// (`VaultValidator` and `VaultPackCatalogService.installPack`) and the licence service, which holds
// an uploaded vault to them before it signs and publishes it as a company vault.
//
// **Foundation only and self-contained.** The app compiles this one file into its own target
// (`project.base.yml`, `project.phone-only.yml`), so the phone and the service run this code, not
// two restatements of it. It must not refer to anything else in this package. It verifies no key
// and no signature: those stay restated in the app, as every other part of this package is.
//
// It is the part of the phone's validator that needs none of the app's models. The rest stays in the
// app and runs on install: reference documents, procedures' step graphs, rule chains, table checks,
// site documents, the core-size warning, and the pack's signature and `pack.json`.

public enum VaultPackRules {

    /// Minimum grounding rules every vault must keep, regardless of what its manifest says.
    public static let requiredRuleThemes = ["fabricate", "cite"]

    /// The parts of a vault's `manifest.json` these rules read.
    public struct Manifest: Equatable {
        public var id: String
        public var name: String
        /// The core files, in prompt order.
        public var files: [String]
        /// How many reference documents (`documents`) the manifest lists.
        public var documentCount: Int
        public var promptRules: [String]
        /// `gating.iap`: the pack id the vault is unlocked by.
        public var gatingIAP: String?
        /// Whether the manifest lists site documents (`sites`, Plan HV) at all.
        public var hasSites: Bool
        /// `procedures_dir`: the folder whose JSON files are the vault's procedures.
        public var proceduresDir: String?

        public init(id: String, name: String, files: [String], documentCount: Int = 0, promptRules: [String] = [],
                    gatingIAP: String? = nil, hasSites: Bool = false, proceduresDir: String? = nil) {
            self.id = id; self.name = name; self.files = files; self.documentCount = documentCount
            self.promptRules = promptRules; self.gatingIAP = gatingIAP; self.hasSites = hasSites
            self.proceduresDir = proceduresDir
        }

        /// Read from `manifest.json`'s bytes, for a vault that has not been through the app's own
        /// decoder (an upload to the service, which writes `version` and `gating` itself). Nil when
        /// the bytes are not a JSON object. A key that is absent, `null` or of the wrong type reads
        /// as absent, except `documents` and `sites`, which count as present whenever they are
        /// anything but absent, `null` or empty: a pack may carry neither.
        public init?(json data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func present(_ key: String) -> Any? { object[key].flatMap { $0 is NSNull ? nil : $0 } }
            id = present("id") as? String ?? ""
            name = present("name") as? String ?? ""
            files = present("files") as? [String] ?? []
            if let list = present("documents") as? [Any] { documentCount = list.count } else { documentCount = present("documents") == nil ? 0 : 1 }
            promptRules = present("prompt_rules") as? [String] ?? []
            gatingIAP = (present("gating") as? [String: Any])?["iap"] as? String
            hasSites = present("sites") != nil
            proceduresDir = present("procedures_dir") as? String
        }
    }

    // MARK: - The manifest (VaultValidator)

    /// What is wrong with the manifest itself, in the order and words the phone's validator has
    /// always reported them. `manualOnly` is the app's manual-only vault, which has no grounding
    /// rules of its own; a pack is never manual-only.
    public static func manifestIssues(_ manifest: Manifest, manualOnly: Bool = false) -> [String] {
        var issues: [String] = []
        if manifest.id.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("manifest id is empty") }
        if manifest.files.isEmpty && manifest.documentCount == 0 {
            issues.append("manifest lists no files and no documents")
        }
        if manifest.promptRules.isEmpty && !manualOnly {
            issues.append("manifest must include prompt_rules (grounding discipline)")
        } else if !manualOnly {
            let joined = manifest.promptRules.joined(separator: " ").lowercased()
            for theme in requiredRuleThemes where !joined.contains(theme) {
                issues.append("prompt_rules should address '\(theme)' (anti-fabrication / source citation)")
            }
        }
        return issues
    }

    /// What is wrong with one listed core file, given its text. Pass nil for `contents` when the
    /// file is absent or is not UTF-8: the phone reads a core file as text or not at all.
    public static func listedFileIssue(_ file: String, contents: String?) -> String? {
        guard let contents else { return "listed file missing: \(file)" }
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "listed file is empty: \(file)" }
        return nil
    }

    /// The procedure the phone could not read, by its file name.
    public static func procedureDoesNotDecode(_ fileName: String) -> String {
        "procedure does not decode: \(fileName)"
    }

    /// Whether a vault-relative path is one of the vault's procedures: a `.json` file directly in
    /// `procedures_dir`, as the phone lists that folder (not its subfolders).
    public static func isProcedureFile(_ path: String, proceduresDir: String) -> Bool {
        var folder = proceduresDir
        while folder.hasPrefix("./") { folder.removeFirst(2) }
        while folder.hasSuffix("/") { folder.removeLast() }
        let parent = (path as NSString).deletingLastPathComponent
        return parent == folder && (path as NSString).pathExtension.lowercased() == "json"
    }

    // MARK: - The pack (installPack)

    /// What makes the vault unfit to be the pack `packId`, in the order and words the phone's
    /// install has always refused it: its gating must name the pack, and a pack carries no reference
    /// documents (customers load their own manuals) and no site documents.
    public static func packIssues(_ manifest: Manifest, packId: String) -> [String] {
        var issues: [String] = []
        if manifest.gatingIAP != packId { issues.append("vault gating must name the pack id") }
        if manifest.documentCount != 0 { issues.append("a pack must not ship documents; customers load their own manuals") }
        // A sellable pack describes products, not customers' sites (Plan HV, decided 2026-10-20).
        if manifest.hasSites { issues.append("a pack must not carry site documents; sites belong in a customer's own vault") }
        return issues
    }
}
