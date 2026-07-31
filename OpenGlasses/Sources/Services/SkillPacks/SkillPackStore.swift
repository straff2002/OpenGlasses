import Foundation

/// Plan BX P1 — installed skill packs: the install pipeline and the persisted registry.
///
/// Layout: `Documents/skillpacks/<id>/<version>/` holds the pack's manifest + payload files;
/// `state.json` (via `JSONStore`, BB salvage semantics) records what's installed, which version is
/// active, whether the signature verified, and the decode report from install time. Install and
/// upgrade are the same operation — a new version lands beside the old, the active pointer moves,
/// and remove deletes the pack's whole directory.
///
/// P1 takes the pack as `(manifestData, files)` — the zip download/extract edge is P2's pipeline;
/// everything from signature to registry merge is exercised headless through this type.
@MainActor
final class SkillPackStore: ObservableObject {

    struct InstalledPack: Codable, Equatable, Identifiable {
        let id: String              // pack id (reverse-DNS)
        var activeVersion: String
        var name: String
        var summary: String
        var enabled: Bool
        /// False = developer-mode unsigned install; surfaced loudly in any listing.
        var signatureVerified: Bool
        var installedAt: Date
        /// Human-readable decode report from install ("clean" or what was dropped) — the BB
        /// lesson applied to packs: a partial load is visible state, not a log line.
        var decodeSummary: String
        var actionCount: Int
    }

    enum InstallResult: Equatable {
        case installed(warnings: [String])
        case rejected(reasons: [String])
    }

    @Published private(set) var installedPacks: [InstalledPack] = []

    private let directory: URL
    private let stateURL: URL
    private let currentBuild: Int
    private let nativeToolNames: () -> Set<String>
    private let publicKeyBase64: String
    private var manifestCache: [String: SkillPackManifest] = [:]
    /// Set when the state blob was unreadable at load (locked file protection): saving would
    /// destroy data we never got to see, so mutations are refused until a clean load.
    private var savingAllowed = true

    init(
        directory: URL? = nil,
        currentBuild: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0,
        nativeToolNames: @escaping () -> Set<String> = { [] },
        publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64
    ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? docs.appendingPathComponent("skillpacks", isDirectory: true)
        self.stateURL = self.directory.appendingPathComponent("state.json")
        self.currentBuild = currentBuild
        self.nativeToolNames = nativeToolNames
        self.publicKeyBase64 = publicKeyBase64
        load()
    }

    // MARK: - Install / remove

    /// Validate and install a pack (or a new version of an installed pack).
    ///
    /// Order matters and is deliberate: signature → decode → validate → write. The signature is
    /// checked over the raw bytes *before* anything is parsed, so a tampered pack never reaches
    /// the decoder; developer mode admits unsigned packs but records that fact on the row.
    func install(
        manifestData: Data,
        files: [String: Data] = [:],
        signatureBase64: String?,
        developerMode: Bool = false
    ) -> InstallResult {
        guard savingAllowed else {
            return .rejected(reasons: ["pack state is unreadable (device locked?) — try again after unlock"])
        }

        var warnings: [String] = []
        var signatureVerified = false
        if let signatureBase64 {
            guard SkillPackSignature.verify(
                signatureBase64: signatureBase64,
                manifestData: manifestData,
                payloadFiles: files,
                publicKeyBase64: publicKeyBase64) else {
                return .rejected(reasons: ["signature verification failed"])
            }
            signatureVerified = true
        } else if developerMode {
            warnings.append("UNSIGNED — developer-mode install")
        } else {
            return .rejected(reasons: ["pack is unsigned (developer mode required for unsigned installs)"])
        }

        let (decoded, report) = SkillPackManifest.lossyDecode(manifestData)
        guard let manifest = decoded else {
            return .rejected(reasons: ["manifest unreadable — id/version/name missing or not JSON"])
        }

        switch SkillPackValidator.validate(
            manifest: manifest, report: report,
            currentBuild: currentBuild, nativeToolNames: nativeToolNames()) {
        case .rejected(let reasons):
            return .rejected(reasons: reasons)
        case .accepted(let validatorWarnings):
            warnings.append(contentsOf: validatorWarnings)
        }

        do {
            let versionDir = packDirectory(id: manifest.id, version: manifest.version)
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
            try manifestData.write(to: versionDir.appendingPathComponent("skillpack.json"))
            for (path, data) in files {
                // Payload paths are relative and must stay inside the pack directory.
                guard !path.hasPrefix("/"), !path.contains("..") else {
                    return .rejected(reasons: ["payload path '\(path)' escapes the pack directory"])
                }
                let dest = versionDir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            }
        } catch {
            return .rejected(reasons: ["couldn't write pack files: \(error.localizedDescription)"])
        }

        let row = InstalledPack(
            id: manifest.id,
            activeVersion: manifest.version,
            name: manifest.name,
            summary: manifest.summary,
            enabled: true,
            signatureVerified: signatureVerified,
            installedAt: Date(),
            decodeSummary: report.summary,
            actionCount: manifest.actions.count)
        if let index = installedPacks.firstIndex(where: { $0.id == manifest.id }) {
            installedPacks[index] = row      // upgrade: pointer moves, enabled state resets to on
        } else {
            installedPacks.append(row)
        }
        manifestCache[manifest.id] = manifest
        save()
        NSLog("[SkillPacks] Installed %@ %@ (%d actions, %@)",
              manifest.id, manifest.version, manifest.actions.count,
              signatureVerified ? "signed" : "UNSIGNED")
        return .installed(warnings: warnings)
    }

    func remove(id: String) {
        guard savingAllowed else { return }
        installedPacks.removeAll { $0.id == id }
        manifestCache[id] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        save()
    }

    /// The per-pack kill switch: a disabled pack's actions vanish from the registry merge on next
    /// build; nothing else about it changes.
    func setEnabled(_ enabled: Bool, id: String) {
        guard savingAllowed, let index = installedPacks.firstIndex(where: { $0.id == id }) else { return }
        installedPacks[index].enabled = enabled
        save()
    }

    // MARK: - Reads

    /// Manifests of enabled packs, loaded from the active version on disk (cached per process).
    func activeManifests() -> [SkillPackManifest] {
        installedPacks.filter(\.enabled).compactMap { pack in
            if let cached = manifestCache[pack.id] { return cached }
            let url = packDirectory(id: pack.id, version: pack.activeVersion)
                .appendingPathComponent("skillpack.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            let (manifest, _) = SkillPackManifest.lossyDecode(data)
            manifestCache[pack.id] = manifest
            return manifest
        }
    }

    private func packDirectory(id: String, version: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    // MARK: - Persistence (JSONStore / BB semantics)

    private func load() {
        switch JSONStore.loadArray(InstalledPack.self, at: stateURL, name: "skillpacks") {
        case .loaded(let packs), .recovered(let packs, _):
            installedPacks = packs
        case .absent:
            installedPacks = []
        case .corrupt:
            installedPacks = []   // blob backed up by JSONStore; start fresh on explicit action
        case .unreadable:
            installedPacks = []
            savingAllowed = false
        }
    }

    private func save() {
        guard savingAllowed else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(installedPacks)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("[SkillPacks] state save failed: %@", error.localizedDescription)
        }
    }
}
