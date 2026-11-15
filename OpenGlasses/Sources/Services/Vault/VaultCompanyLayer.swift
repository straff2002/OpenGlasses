import Foundation

/// Plan LV — a company layer on the phone: a company's own files added to a published vault,
/// installed as their own baseline beside the vault's (`Documents/Vaults/_baselines/{id}.company/`)
/// so a partner's update and a company's update never replace each other.
///
/// The layer is a signed EG pack held to the rules of a layer, not of a vault: it must name its
/// pack, add files only (never one the vault it extends already lists, decision 4) and carry no
/// documents and no site documents (`VaultLayerMerge.manifest`, `VaultPackRules.layerIssues`). It
/// needs no grounding rules of its own: the publisher's vault carries them, and the merged vault is
/// what a job reads. A layer that fails any of this is refused whole and named on its row; nothing
/// of it is installed.
///
/// What a job reads is `VaultRegistry`'s merged manifest (`layered`) and `VaultStore`'s reads, in
/// the order publisher baseline → company layer → technician overlay. The registry file on disk
/// stays the publisher's, so a manual re-lay (`VaultDocumentCarry.relay`) and a publisher update
/// rebuild the publisher's baseline alone. Removing the layer leaves the publisher's vault and the
/// technician's edits.
enum VaultCompanyLayer {

    /// The directory a vault's company layer lives in, beside its baseline.
    static func directory(baseId: String) -> URL {
        VaultImporter.baselineDirectory(for: baseId + suffix)
    }

    static let suffix = ".company"

    struct Installed: Equatable {
        /// The vault the layer extends.
        let baseId: String
        let pack: VaultPackManifest
        let manifest: VaultManifest
    }

    /// The layer installed over `baseId`, or nil.
    static func installed(baseId: String) -> Installed? {
        let root = directory(baseId: baseId)
        guard let packData = try? Data(contentsOf: root.appendingPathComponent(VaultPackManifest.filename)),
              let pack = try? JSONDecoder().decode(VaultPackManifest.self, from: packData),
              let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: manifestData) else { return nil }
        return Installed(baseId: baseId, pack: pack, manifest: manifest)
    }

    /// The installed layer whose own vault id is `vaultId` (the catalog row's), or nil.
    static func installed(vaultId: String) -> Installed? {
        let parent = VaultImporter.baselineDirectory(for: "x").deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return nil }
        for name in names.sorted() where name.hasSuffix(suffix) && name.count > suffix.count {
            let base = String(name.dropLast(suffix.count))
            if let layer = installed(baseId: base), layer.pack.vaultId == vaultId { return layer }
        }
        return nil
    }

    /// `publisher` with its company layer laid over it, or `publisher` itself when it has none or
    /// the layer no longer fits it.
    static func layered(_ publisher: VaultManifest) -> VaultManifest {
        guard let layer = installed(baseId: publisher.id),
              case .success(let merged) = VaultLayerMerge.manifest(publisher: publisher, company: layer.manifest) else {
            return publisher
        }
        return merged
    }

    /// Validate a layer's pack as a layer over the installed vault `baseId` and install it. Nil, or
    /// why it was refused, in words for the row ("Couldn't install ⟨name⟩: ⟨reason⟩.").
    @MainActor
    static func install(zipData: Data, vault: CompanyVaultCatalog.Vault, baseId: String, publicKeyBase64: String,
                        currentBuild: Int) -> String? {
        let packData: Data
        let files: [String: Data]
        switch VaultPackArchive.extract(zipData: zipData) {
        case .failure(.notAZip): return "not a readable pack archive"
        case .failure(.missingPackManifest): return "pack has no pack.json"
        case .failure(.missingVaultManifest): return "pack has no manifest.json"
        case .success(let (p, f)): packData = p; files = f
        }
        guard VaultPackSignature.verify(signatureBase64: vault.packSignature, packManifestData: packData,
                                        files: files, publicKeyBase64: publicKeyBase64) else {
            return "pack signature invalid — refusing to install"
        }
        guard let pack = try? JSONDecoder().decode(VaultPackManifest.self, from: packData) else { return "pack.json unreadable" }
        guard pack.id == vault.id else { return "pack id does not match the catalog entry" }
        guard VaultPackManifest.isPackProductId(pack.id) else { return "pack id is not a vault product id" }
        if let min = pack.minAppBuild, min > currentBuild { return "this pack needs app build \(min) or newer" }
        guard let manifestData = files["manifest.json"],
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: manifestData) else {
            return "vault manifest unreadable"
        }
        guard manifest.id == pack.vaultId, pack.vaultId == vault.vaultId else {
            return "pack.json vaultId does not match manifest.json id"
        }
        guard manifest.gating.iap == pack.id else { return "vault gating must name the pack id" }
        guard let base = VaultImporter.installedManifest(id: baseId) else {
            return String(localized: "the vault it adds to isn't on this phone yet")
        }
        // A layer already here that the vault's own update has made unfit is never read again;
        // it goes, so the row keeps naming the problem until the company fixes its layer.
        if let old = installed(baseId: baseId), case .failure = VaultLayerMerge.manifest(publisher: base, company: old.manifest) {
            remove(baseId: baseId)
        }
        // The merge first: a layer that would replace one of the publisher's files is refused
        // whole, whatever else is right with it.
        switch VaultLayerMerge.manifest(publisher: base, company: manifest) {
        case .failure(.replacesPublisherFiles(let names)):
            return String(localized: "it would replace \(names.joined(separator: ", ")) in \(base.name), and your company's own files may only be added")
        case .failure(.notALayer(let issues)):
            return issues.first ?? "not a company layer"
        case .success:
            break
        }
        // Its own files, as a layer: listed, inside the layer, and readable text.
        guard !manifest.files.isEmpty else { return "a company layer lists no files" }
        var laid: [(path: String, data: Data)] = []
        for file in manifest.files {
            var path = file
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                return "listed file missing: \(file)"
            }
            let data = files[path]
            if let issue = VaultPackRules.listedFileIssue(file, contents: data.flatMap { String(data: $0, encoding: .utf8) }) {
                return issue
            }
            laid.append((path, data ?? Data()))
        }

        let fm = FileManager.default
        let target = directory(baseId: baseId)
        let staging = target.appendingPathExtension("staging-\(UUID().uuidString.prefix(8))")
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (path, data) in laid {
                let url = staging.appendingPathComponent(path)
                guard VaultManualRemoval.isContained(path, in: staging) else { throw CocoaError(.fileWriteInvalidFileName) }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(pack).write(to: staging.appendingPathComponent(VaultPackManifest.filename))
            // Swap in whole, keeping the layer already here until the new one is in place.
            let existed = fm.fileExists(atPath: target.path)
            let backup = target.appendingPathExtension("rollback-\(UUID().uuidString.prefix(8))")
            if existed { try fm.moveItem(at: target, to: backup) }
            do {
                try fm.moveItem(at: staging, to: target)
            } catch {
                if existed { try? fm.moveItem(at: backup, to: target) }
                throw error
            }
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(at: staging)
            return error.localizedDescription
        }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        return nil
    }

    /// Take the layer off `baseId`. The vault and the technician's overlay are left as they are.
    @MainActor
    static func remove(baseId: String) {
        try? FileManager.default.removeItem(at: directory(baseId: baseId))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
    }
}
