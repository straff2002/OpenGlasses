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
    ///
    /// Only the electrical starter declares `trades`: the refrigeration vault is every Field Assist
    /// install's default, so declaring a trade there would put that trade's tiles on nearly every
    /// technician's grid. The technician, the organisation or an authored vault turns a trade on;
    /// the electrical starter is chosen as a default only by an electrician, and says so.
    nonisolated private static let builtInManifests: [VaultManifest] = [
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
        // The electrical starter (Plan JJ P4): safety rules, empty fault-code and parts files, and
        // a `chains.md` holding the schema and the guide's invented example, so an electrician
        // starts from a file that parses. No standard's text, no table and no rule ships in it
        // (Plan JJ decision 1, Plan IN decision 6); its folder's `manifest.json` is the same vault
        // as a template an organisation copies, adds its own code PDFs to and imports.
        VaultManifest(
            id: VaultRegistry.electricalStarterId,
            name: "Electrical Service",
            version: "1.0.0",
            files: [
                "safety.md",
                "error_codes.md",
                "parts.md",
                "chains.md"
            ],
            proceduresDir: nil,
            gating: .init(iap: "field_assist_electrical"),
            promptRules: [
                "Never fabricate a rating, a conductor size, a table value, a rule, a fault code or a procedure.",
                "Use only the vault contents, the retrieved passages of the organisation's own code books and manuals, and the technician's stated observations.",
                "Cite the rule, the table or the manual page on every factual claim; a value from a table names its table, row, column and page.",
                "Never guess a rating, a size, a setting or a limit: if the loaded books do not give it, say so and recommend checking the printed book or escalating.",
                "Before any step that opens a panel or an enclosure, remind the technician to isolate the supply, lock it off and prove it dead with a tester checked on a known source, and to follow the organisation's own safety rules."
            ],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: true,
            trades: ["electrical"]
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

    /// The bundled electrical starter's id; its resources are `Vaults/electrical/`.
    nonisolated static let electricalStarterId = "electrical"

    /// User-installed (Plan H) manifests, loaded from the import registry. Cached; call
    /// `reloadUserManifests()` after an import/uninstall.
    private var userManifests: [VaultManifest] = VaultImporter.installedManifests()

    /// All manifests known to the registry, regardless of unlock state (built-in + user-installed).
    var allManifests: [VaultManifest] { Self.builtInManifests + userManifests.filter { !$0.isPersonalLibrary } }

    /// Re-read user-installed manifests after an import or uninstall.
    func reloadUserManifests() {
        userManifests = VaultImporter.installedManifests()
        storeCache.removeAll()
    }

    private var storeCache: [String: VaultStore] = [:]

    private init() {}

    /// A bundled manifest by id, readable off the main actor — the quick-action grid reads the
    /// default vault's declared trades from wherever it is built.
    nonisolated static func builtInManifest(id: String) -> VaultManifest? {
        builtInManifests.first { $0.id == id }
    }

    /// Look up a manifest by id.
    func manifest(id: String) -> VaultManifest? {
        allManifests.first { $0.id == id }
    }

    /// Whether the user has unlocked this vault.
    /// IAP-gated vaults check StoreKit; vaults without an `iap` requirement are always unlocked.
    ///
    /// This is a service boundary, not a UI hint: `FieldSessionService` and the Field Assist tools
    /// route through here, so a denied decision blocks a vault read even when no settings screen is
    /// involved.
    func isUnlocked(_ manifest: VaultManifest) -> Bool {
        if manifest.isPersonalLibrary { return PersonalManualLibrary.permitted }
        if let pack = VaultImporter.installedPack(for: manifest.id)?.id {
            // A personal purchase cannot re-authorise documents withdrawn by the employer.
            let manager = OrgProfileManager.shared
            if manager.profile?.vaultPack?.packId == pack,
               (manager.contentLocked || !FieldAssistEntitlement.shared.has(.orgConfiguration)) { return false }
            if let departure = OrgDepartureService.loadStored(), departure.packId == pack {
                let renewed = manager.lease?.isInForce == true &&
                    (departure.reason == .lapsed || manager.record?.enrolmentId != departure.enrolmentId)
                if !renewed { return false }
            }
        }
        guard let iap = manifest.gating.iap else { return true }
        switch iap {
        case "medical_compliance":
            return StoreKitService.shared.isMedicalComplianceActive
        case "field_assist_refrigeration", "field_assist_it", "field_assist_electrical":
            return FieldAssistEntitlement.shared.has(.bundledVaults)
        case "enterprise":
            // A vault of the reader's own (Plan H). Gated on the capability, not a tier: a
            // subscription and a team licence both include it, the retired one-time unlock does not.
            return FieldAssistEntitlement.shared.has(.ownVaults)
        default:
            // A vault pack (Plan EG): its own store product, a licence that lists it, or enterprise.
            guard VaultPackManifest.isPackProductId(iap) else { return false }
            let decision = FieldAssistEntitlement.shared.decision()
            guard decision.isGranted else { return false }
            let licensePack = VaultImporter.installedPack(for: manifest.id)?.effectiveLicensePack ?? manifest.id
            return VaultPackAccess.isUnlocked(productId: iap, licensePack: licensePack,
                                              purchasedProducts: VerifiedStorePurchaseRecorder.shared.packProductIds,
                                              licensedPacks: FieldAssistEntitlement.shared.grantedPacks(),
                                              capabilities: FieldAssistEntitlement.shared.capabilities())
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

/// Resolve conversational selections without guessing a different technical knowledge source.
/// Defaults remain exact persisted IDs; a removed default must not match an unrelated display name.
enum VaultSelection {
    enum Failure: LocalizedError {
        case missingDefault(String)
        case unknown(String)
        case ambiguous(String)

        var errorDescription: String? {
            switch self {
            case .missingDefault(let id): return "The configured default vault [\(id)] is not installed."
            case .unknown(let value): return "No installed vault matches '\(value)'."
            case .ambiguous(let value): return "More than one installed vault matches '\(value)'; use its exact ID."
            }
        }
    }

    static func resolve(_ requested: String?, defaultId: String, manifests: [VaultManifest]) throws -> String {
        let value = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = normalized(value)
        if value.isEmpty || ["default", "defaultvault", "configureddefault", "configureddefaultvault"].contains(key) {
            guard manifests.contains(where: { $0.id == defaultId }) else {
                throw Failure.missingDefault(defaultId)
            }
            return defaultId
        }
        // Exact IDs are authoritative, even if another vault has the same display name.
        if let exact = manifests.first(where: { $0.id == value }) { return exact.id }
        guard !key.isEmpty else { throw Failure.unknown(value) }
        var matches = manifests.filter { normalized($0.id) == key || normalized($0.name) == key }
        // "The … vault": a name copied from the app's own sentence about it carries words the
        // vault's name does not (Plan KD P0). Tried only when the name as given matched nothing,
        // on both sides alike, so a vault really named "… Vault" still matches as it always did.
        let bare = normalized(withoutVaultWords(value))
        if matches.isEmpty, !bare.isEmpty, bare != key {
            matches = manifests.filter {
                normalized($0.id) == bare || normalized($0.name) == bare
                    || normalized(withoutVaultWords($0.name)) == bare
            }
        }
        guard matches.count == 1 else {
            if matches.isEmpty { throw Failure.unknown(value) }
            throw Failure.ambiguous(value)
        }
        return matches[0].id
    }

    /// `value` with a leading "the" and a trailing "vault" (or "vaults") left out, word-wise.
    static func withoutVaultWords(_ value: String) -> String {
        var words = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func bare(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        if let first = words.first, bare(first) == "the" { words.removeFirst() }
        if let last = words.last, ["vault", "vaults"].contains(bare(last)) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
