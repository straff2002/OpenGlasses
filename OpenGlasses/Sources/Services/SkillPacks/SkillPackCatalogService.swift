import Foundation

/// Plan BX P2 — fetch the catalog, and run one pack through download → hash → extract → install.
///
/// Network is injected as a closure, so the entire pipeline — including failure ordering — runs
/// headless in tests against fixture bytes. The service holds per-pack UI state; the store stays
/// the single owner of what's installed.
@MainActor
final class SkillPackCatalogService: ObservableObject {

    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded([SkillPackCatalogEntry])
        case failed(String)
    }

    enum InstallState: Equatable {
        case downloading
        case installing
        case installed(warnings: [String])
        case failed(String)
    }

    @Published private(set) var catalogState: CatalogState = .idle
    /// Per-pack install progress, keyed by pack id.
    @Published private(set) var installStates: [String: InstallState] = [:]

    private let store: SkillPackStore
    private let fetch: (URL) async throws -> Data
    private let catalogURL: () -> URL?
    private let onInstalled: () -> Void

    init(
        store: SkillPackStore,
        catalogURL: @escaping () -> URL? = { URL(string: Config.skillPackCatalogURL) },
        fetch: @escaping (URL) async throws -> Data = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        },
        onInstalled: @escaping () -> Void = {}
    ) {
        self.store = store
        self.catalogURL = catalogURL
        self.fetch = fetch
        self.onInstalled = onInstalled
    }

    func loadCatalog() async {
        guard let url = catalogURL() else {
            catalogState = .failed("No catalog URL configured")
            return
        }
        catalogState = .loading
        do {
            let envelope = try await fetch(url)
            switch SkillPackCatalog.parse(envelopeData: envelope) {
            case .success(let entries):
                catalogState = .loaded(entries)
            case .failure(let error):
                catalogState = .failed(Self.describe(error))
            }
        } catch {
            catalogState = .failed("Couldn't reach the catalog: \(error.localizedDescription)")
        }
    }

    /// Download → hash-verify → extract → install. Every stage failure lands in `installStates`
    /// with a reason; nothing partial ever reaches the store (its own signature check is the
    /// last gate regardless).
    func install(_ entry: SkillPackCatalogEntry) async {
        guard let url = URL(string: entry.downloadURL) else {
            installStates[entry.id] = .failed("bad download URL")
            return
        }
        installStates[entry.id] = .downloading

        let zipData: Data
        do {
            zipData = try await fetch(url)
        } catch {
            installStates[entry.id] = .failed("download failed: \(error.localizedDescription)")
            return
        }

        // The index promised these exact bytes; anything else is a swapped or truncated artifact.
        let digest = SkillPackArchive.sha256Hex(zipData)
        guard digest == entry.sha256.lowercased() else {
            installStates[entry.id] = .failed("download doesn't match the catalog's checksum")
            return
        }

        installStates[entry.id] = .installing
        switch SkillPackArchive.extract(zipData: zipData) {
        case .failure(let error):
            installStates[entry.id] = .failed(
                error == .missingManifest ? "pack has no skillpack.json" : "not a readable pack archive")
        case .success(let (manifestData, files)):
            switch store.install(
                manifestData: manifestData,
                files: files,
                signatureBase64: entry.packSignature.isEmpty ? nil : entry.packSignature,
                developerMode: Config.skillPackDevModeEnabled
            ) {
            case .installed(let warnings):
                installStates[entry.id] = .installed(warnings: warnings)
                onInstalled()
            case .rejected(let reasons):
                installStates[entry.id] = .failed(reasons.joined(separator: "; "))
            }
        }
    }

    private static func describe(_ error: SkillPackCatalog.CatalogError) -> String {
        switch error {
        case .notAnEnvelope: return "catalog format not recognized"
        case .badSignature: return "catalog signature invalid — refusing the index"
        case .unreadableIndex: return "catalog index unreadable"
        case .unsupportedVersion(let v): return "catalog version \(v) needs a newer app build"
        }
    }
}

/// Plan BX P2 — per-pack setting values, persisted under `skillpack.<packId>.<key>` and rendered
/// by the host from the pack's typed declarations (settings-as-schema: no per-pack UI code).
/// Values reach bindings as `{{setting.<key>}}` template substitutions.
enum SkillPackSettings {

    static func defaultsKey(packId: String, key: String) -> String {
        "skillpack.\(packId).\(key)"
    }

    static func value(packId: String, key: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(packId: packId, key: key))
    }

    static func setValue(_ value: String?, packId: String, key: String) {
        let defaults = UserDefaults.standard
        if let value { defaults.set(value, forKey: defaultsKey(packId: packId, key: key)) }
        else { defaults.removeObject(forKey: defaultsKey(packId: packId, key: key)) }
    }

    /// All configured values for a pack, given its declared settings.
    static func values(packId: String, declarations: [SkillPackManifest.SettingDeclaration]) -> [String: String] {
        var out: [String: String] = [:]
        for declaration in declarations {
            if let v = value(packId: packId, key: declaration.key) { out[declaration.key] = v }
        }
        return out
    }

    /// Remove a pack's stored values on uninstall, so a reinstall starts clean.
    static func removeAll(packId: String, declarations: [SkillPackManifest.SettingDeclaration]) {
        for declaration in declarations { setValue(nil, packId: packId, key: declaration.key) }
    }
}
