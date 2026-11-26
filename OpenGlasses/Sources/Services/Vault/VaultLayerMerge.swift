import Foundation

/// Plan LV — what each core file of a published vault resolves to, pure.
///
/// Three layers, read in order and the last one that has a file wins: the **publisher's baseline**
/// (the partner's pack), the **company layer** (a catalog row that `extends` the vault, installed as
/// its own baseline) and the **technician's overlay** (`Documents/Vaults/{id}/`).
///
/// The company layer is add-only (decision 4): it may add files and prompt rules, never replace one
/// of the publisher's files, so a partner's update can never collide with a company's change. A
/// layer that lists a file the publisher's vault has is refused as a whole, never applied in part.
/// The technician's overlay works as it always has: it edits files already listed (publisher's or
/// company's) and adds none. Removing the company layer leaves the publisher's vault and the
/// technician's edits.
enum VaultLayerMerge {

    /// Which layer a file is read from.
    enum Layer: String, Equatable, Sendable {
        case publisher, company, technician
    }

    /// The part of one layer's manifest the merge reads.
    struct Part: Equatable, Sendable {
        var files: [String]
        var promptRules: [String]

        init(files: [String], promptRules: [String] = []) {
            self.files = files
            self.promptRules = promptRules
        }

        init(_ manifest: VaultManifest) {
            self.init(files: manifest.files, promptRules: manifest.promptRules)
        }
    }

    struct Merged: Equatable, Sendable {
        /// The core files in prompt order: the publisher's, then the company's additions.
        let files: [String]
        /// The publisher's prompt rules, then the company's, a rule repeated word for word kept once.
        let promptRules: [String]
        /// The files the company layer added, in its order.
        let companyFiles: [String]
        /// Where each listed file is read from.
        let sources: [String: Layer]

        func source(of file: String) -> Layer? { sources[file] }
    }

    enum Refusal: Error, Equatable {
        /// The company layer lists files the publisher's vault already has.
        case replacesPublisherFiles([String])
        /// The layer is not one a vault can take (it ships documents or site documents): the
        /// licence core's words (`VaultPackRules.layerIssues`).
        case notALayer([String])
    }

    /// The merged file list, rules and sources. `technicianFiles` are the paths present in the
    /// overlay; one the merged list does not name is not read (as today).
    static func merge(publisher: Part, company: Part?, technicianFiles: Set<String> = []) -> Result<Merged, Refusal> {
        var files: [String] = []
        var sources: [String: Layer] = [:]
        var seen = Set<String>()
        for file in publisher.files where seen.insert(VaultPackRules.layerFileKey(file)).inserted {
            files.append(file)
            sources[file] = .publisher
        }
        var rules: [String] = []
        for rule in publisher.promptRules where !rules.contains(rule) { rules.append(rule) }

        var added: [String] = []
        if let company {
            let collisions = VaultPackRules.layerCollisions(baseFiles: publisher.files, layerFiles: company.files)
            guard collisions.isEmpty else { return .failure(.replacesPublisherFiles(collisions)) }
            for file in company.files where seen.insert(VaultPackRules.layerFileKey(file)).inserted {
                files.append(file)
                added.append(file)
                sources[file] = .company
            }
            for rule in company.promptRules where !rules.contains(rule) { rules.append(rule) }
        }

        let overlay = Set(technicianFiles.map(VaultPackRules.layerFileKey))
        for file in files where overlay.contains(VaultPackRules.layerFileKey(file)) {
            sources[file] = .technician
        }
        return .success(Merged(files: files, promptRules: rules, companyFiles: added, sources: sources))
    }

    /// The publisher's equipment types, then the company's that it does not already list (as
    /// `VaultPackRules.equipmentTypeKey` compares them). Nil when neither declares a list.
    static func mergedEquipmentTypes(publisher: [String]?, company: [String]?) -> [String]? {
        guard publisher != nil || company != nil else { return nil }
        var merged: [String] = []
        var seen = Set<String>()
        for type in (publisher ?? []) + (company ?? []) where seen.insert(VaultPackRules.equipmentTypeKey(type)).inserted {
            merged.append(type)
        }
        return merged
    }

    /// The vault's manifest with the company layer laid over it: the publisher's manifest in every
    /// field but `files`, `prompt_rules` and `equipment_types`, which are merged (add-only, like the
    /// files: a company names the equipment it services beside the publisher's). Refuses a layer
    /// that would replace a publisher file or that carries documents or site documents.
    static func manifest(publisher: VaultManifest, company: VaultManifest?) -> Result<VaultManifest, Refusal> {
        if let company {
            let issues = VaultPackRules.layerIssues(VaultPackRules.Manifest(company), baseFiles: publisher.files)
            let collisions = VaultPackRules.layerCollisions(baseFiles: publisher.files, layerFiles: company.files)
            guard collisions.isEmpty else { return .failure(.replacesPublisherFiles(collisions)) }
            guard issues.isEmpty else { return .failure(.notALayer(issues)) }
        }
        return merge(publisher: Part(publisher), company: company.map { Part($0) }).map { merged in
            VaultManifest(id: publisher.id, name: publisher.name, version: publisher.version, files: merged.files,
                          proceduresDir: publisher.proceduresDir, documentsDir: publisher.documentsDir,
                          documents: publisher.documents, documentsIncluded: publisher.documentsIncluded,
                          gating: publisher.gating, promptRules: merged.promptRules,
                          sourceAttributionFormat: publisher.sourceAttributionFormat,
                          sourceAttributionRequired: publisher.sourceAttributionRequired, trades: publisher.trades,
                          sites: publisher.sites, vaultOnly: publisher.vaultOnly,
                          equipmentTypes: mergedEquipmentTypes(publisher: publisher.equipmentTypes,
                                                               company: company?.equipmentTypes))
        }
    }
}
