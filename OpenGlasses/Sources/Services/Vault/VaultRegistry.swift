import Foundation

/// Central registry of all knowledge vaults shipped with (or addable to) the app.
///
/// Vaults are discovered from two sources:
///   1. **Built-in manifests** declared in `builtInManifests` — these ship with the app and reference
///      bundled resources under `Vaults/{id}/`.
///   2. **User-uploaded vaults** stored as JSON manifests in `Documents/Vaults/_registry/` (future v2).
///
/// The registry handles IAP-gated visibility and produces `VaultStore` instances on demand.
@MainActor
final class VaultRegistry {
    static let shared = VaultRegistry()

    /// Manifests bundled with the app. Edit this list to add new vault packs.
    private static let builtInManifests: [VaultManifest] = [
        VaultManifest(
            id: "refrigeration",
            name: "Refrigeration Service",
            version: "1.0.0",
            files: [
                "manufacturers.md",
                "error_codes.md",
                "pt_charts.md",
                "superheat_subcool.md",
                "epa_608.md",
                "safety.md"
            ],
            proceduresDir: "procedures",
            gating: .init(iap: "field_assist_refrigeration"),
            promptRules: [
                "Never fabricate equipment data, error codes, refrigerant properties, or procedures.",
                "Use only the vault contents and the technician's stated observations.",
                "Cite source files on every factual claim.",
                "If unsure, recommend escalating to a human expert rather than guess.",
                "Always remind the technician of relevant safety steps before any action that opens the refrigerant circuit or any electrical panel.",
                "Refer to refrigerants by their full designation (e.g. R-410A, not just 410)."
            ],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: true
        ),
        VaultManifest(
            id: "it_network",
            name: "IT / Network Service",
            version: "1.0.0",
            files: [
                "error_codes.md",
                "topology.md",
                "runbooks.md",
                "inventory_schema.md",
                "safety.md"
            ],
            proceduresDir: "procedures",
            gating: .init(iap: "field_assist_it"),
            promptRules: [
                "Never fabricate error codes, device specifications, or procedures.",
                "Use only the vault contents and the technician's stated observations.",
                "Cite source files on every factual claim.",
                "If unsure, recommend escalating to a senior engineer rather than guess.",
                "Confirm change-control / maintenance-window approval before any disruptive action (reboot, failover, firmware).",
                "Apply electrical and ESD safety in racks and IDFs; LOTO PDUs before service."
            ],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: true
        ),
        VaultManifest(
            id: "health",
            name: "Personal Health Vault",
            version: "1.0.0",
            files: [
                "biometrics.md",
                "conditions.md",
                "dietary_context.md",
                "lab_baselines.md",
                "medications.md",
                "wearables.md"
            ],
            proceduresDir: nil,
            gating: .init(iap: "medical_compliance"),
            promptRules: [
                "Never fabricate chart data.",
                "Use only the visible markdown vault, the user's message, attached image, or attached audio transcript.",
                "Be concise, concrete, and grounded.",
                "For food and medication questions, first ground yourself in the chart before giving a caution.",
                "Distinguish clearly between chart facts and general safety guidance."
            ],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: true
        ),
        VaultManifest(
            id: "notes",
            name: "Personal Notes",
            version: "1.0.0",
            files: [
                "general.md",
                "people.md",
                "ideas.md",
                "todos.md"
            ],
            proceduresDir: nil,
            gating: .init(iap: nil),   // free — always unlocked
            promptRules: [
                "Never fabricate the user's notes.",
                "Answer only from the notes vault and the user's message; if it isn't recorded, say so.",
                "Cite the source file for facts drawn from the notes.",
                "Be concise."
            ],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: false
        )
    ]

    /// User-installed (Plan H) manifests, loaded from the import registry. Cached; call
    /// `reloadUserManifests()` after an import/uninstall.
    private var userManifests: [VaultManifest] = VaultImporter.installedManifests()

    /// All manifests known to the registry, regardless of unlock state (built-in + user-installed).
    var allManifests: [VaultManifest] { Self.builtInManifests + userManifests }

    /// Re-read user-installed manifests after an import or uninstall.
    func reloadUserManifests() {
        userManifests = VaultImporter.installedManifests()
        storeCache.removeAll()
    }

    private var storeCache: [String: VaultStore] = [:]

    private init() {}

    /// Look up a manifest by id.
    func manifest(id: String) -> VaultManifest? {
        allManifests.first { $0.id == id }
    }

    /// Whether the user has unlocked this vault.
    /// IAP-gated vaults check StoreKit; vaults without an `iap` requirement are always unlocked.
    func isUnlocked(_ manifest: VaultManifest) -> Bool {
        guard let iap = manifest.gating.iap else { return true }
        switch iap {
        case "medical_compliance":
            return StoreKitService.shared.isMedicalComplianceActive
        case "field_assist_refrigeration", "field_assist_it":
            // MVP: gate on agentModeEnabled until a dedicated IAP ships.
            // Once the per-pack products are live, switch to StoreKit.
            return Config.agentModeEnabled || Config.fieldAssistDeveloperUnlocked
        case "enterprise":
            // Customer-imported vaults (Plan H). Dev-unlock until an enterprise entitlement ships.
            return Config.agentModeEnabled || Config.fieldAssistDeveloperUnlocked
        default:
            return false
        }
    }

    /// Convenience overload.
    func isUnlocked(_ id: String) -> Bool {
        guard let m = manifest(id: id) else { return false }
        return isUnlocked(m)
    }

    /// Get (or create) a VaultStore for a manifest. Cached per-id.
    func store(for manifest: VaultManifest) -> VaultStore {
        if let cached = storeCache[manifest.id] { return cached }
        let store = VaultStore.standard(manifest: manifest)
        storeCache[manifest.id] = store
        return store
    }

    /// Convenience overload returning nil when the id is unknown.
    func store(forId id: String) -> VaultStore? {
        guard let m = manifest(id: id) else { return nil }
        return store(for: m)
    }

    /// Reset cached stores — used by tests.
    func resetCache() { storeCache.removeAll() }
}
