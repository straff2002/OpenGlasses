import Foundation

/// Installed recipe add-ons (Plan GF P2): the files, and the record of what is installed.
///
/// Layout, under `Documents/addons/`:
/// - `<id>/addon.json` — the exact add-on file bytes, as approved (or as edited on the phone).
/// - `<id>/signed.json` — the signed envelope it arrived in, only while it is unedited and its
///   signature verified at install, so the signature can be checked again and travels on export.
/// - `state.json` — the installed records (`InstalledAddOn`), loaded through `JSONStore` with its
///   salvage semantics: one bad record drops that record, not the list; an undecodable blob is
///   backed up before anything is written over it; an unreadable one (file protection while the
///   phone is locked) refuses every change until a clean load.
///
/// The id is a validated reverse-DNS name (lowercase letters, digits, hyphens and dots), which is
/// what makes it safe as a directory name; anything else is refused before a path is built.
///
/// Trust is never taken from the record: a signed add-on's class is resolved again from its stored
/// envelope against the keys the phone trusts now (`trustKeys`), so an organisation add-on demotes
/// the moment its organisation's profile is removed, and the validator then refuses it if it holds
/// a reserved capability. An add-on whose file no longer validates is kept and shown, never run.
@MainActor
final class AddOnStore: ObservableObject {

    /// The trust the signature proved at install time, for listing. What runs is `trust(id:)`.
    enum StoredTrust: Codable, Equatable, Sendable {
        case community
        case vendorSigned
        case organisationSigned(organizationID: String)

        init(_ trust: AddOnTrustClass) {
            switch trust {
            case .community: self = .community
            case .vendorSigned: self = .vendorSigned
            case .organisationSigned(let id): self = .organisationSigned(organizationID: id)
            }
        }
    }

    struct InstalledAddOn: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var version: String
        var name: String
        var summary: String
        var icon: String?
        var enabled: Bool
        var trustAtInstall: StoredTrust
        /// Its source was changed on this phone: any signature is gone and "Edited on this phone"
        /// is shown.
        var editedOnPhone: Bool
        var installedAt: Date
        var updatedAt: Date
        var origin: AddOnOrigin
        var skillNames: [String]

        var isBuiltByAssistant: Bool { origin.isSelfBuilt }
        var selfBuiltProvenance: SelfBuiltAddOnProvenance? {
            if case .selfBuilt(let provenance) = origin { return provenance }
            return nil
        }
    }

    /// An installed add-on loaded for use: its record, its file, and the trust it resolves to now.
    struct Loaded: Equatable, Sendable {
        let record: InstalledAddOn
        let manifest: RecipeAddOnManifest
        let trust: AddOnTrustClass
    }

    /// Why a stored add-on can't be used, shown on its row.
    enum Damage: Error, Equatable, Sendable {
        case fileMissing
        case noLongerValid([String])
    }

    enum StoreError: Error, Equatable {
        /// The state file could not be read (the phone is locked?): nothing may change until it can.
        case unreadable
        case invalidID
        /// The same id is installed at this version or a newer one.
        case notNewer(installed: String)
        case notInstalled
        case writeFailed
    }

    /// The keys a signature is checked against, read when trust is resolved.
    struct TrustKeys: Equatable, Sendable {
        var vendorKeys: [String: String] = AddOnSignature.productionVendorKeys
        var trustedOrganisations: [String: String] = [:]
    }

    @Published private(set) var installed: [InstalledAddOn] = []

    private let directory: URL
    private let stateURL: URL
    private let trustKeys: @MainActor () -> TrustKeys
    private let nativeToolNames: @MainActor () -> Set<String>
    private let backupDirectory: URL?
    private var savingAllowed = true
    private var cache: [String: Result<Loaded, Damage>] = [:]

    static let fileName = "addon.json"
    static let envelopeName = "signed.json"

    init(directory: URL? = nil,
         trustKeys: @escaping @MainActor () -> TrustKeys = { TrustKeys() },
         nativeToolNames: @escaping @MainActor () -> Set<String> = { [] },
         backupDirectory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? docs.appendingPathComponent("addons", isDirectory: true)
        self.stateURL = self.directory.appendingPathComponent("state.json")
        self.trustKeys = trustKeys
        self.nativeToolNames = nativeToolNames
        self.backupDirectory = backupDirectory
        load()
    }

    var isWritable: Bool { savingAllowed }

    // MARK: - Reads

    func record(id: String) -> InstalledAddOn? { installed.first { $0.id == id } }

    /// What admission needs to know about an id already installed.
    func admissionInstalled(id: String) -> AddOnAdmission.Installed? {
        guard let row = record(id: id) else { return nil }
        return .init(version: row.version, manifest: try? loaded(id: id).get().manifest)
    }

    /// The add-on ready to run, or why it can't. Cached per process; `refreshTrust()` clears it.
    func loaded(id: String) -> Result<Loaded, Damage> {
        if let cached = cache[id] { return cached }
        guard let row = record(id: id), let bytes = fileBytes(id: id) else {
            cache[id] = .failure(.fileMissing)
            return .failure(.fileMissing)
        }
        let trust = resolveTrust(id: id, fileBytes: bytes, editedOnPhone: row.editedOnPhone)
        let report = RecipeAddOnValidator.validate(data: bytes, nativeToolNames: nativeToolNames(), trust: trust)
        let result: Result<Loaded, Damage>
        if let manifest = report.manifest, report.issues.isEmpty, manifest.id == id {
            result = .success(Loaded(record: row, manifest: manifest, trust: trust))
        } else {
            result = .failure(.noLongerValid(report.issues.map(\.description)))
        }
        cache[id] = result
        return result
    }

    /// Every installed add-on that loads, enabled or not, in install order.
    func loadedAddOns() -> [Loaded] {
        installed.compactMap { try? loaded(id: $0.id).get() }
    }

    /// The trust an add-on resolves to now.
    func trust(id: String) -> AddOnTrustClass {
        (try? loaded(id: id).get().trust) ?? .community
    }

    /// The exact file bytes as stored.
    func fileBytes(id: String) -> Data? {
        guard let dir = addOnDirectory(id) else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(Self.fileName))
    }

    /// The source as text, for the source view.
    func sourceText(id: String) -> String? {
        fileBytes(id: id).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// What Export shares: the signed envelope while the add-on is unedited and was signed (so the
    /// signature travels with it), otherwise the file itself. Never a token or a key: the format
    /// has no field that could hold one.
    func exportData(id: String) -> Data? {
        guard let row = record(id: id), let dir = addOnDirectory(id) else { return nil }
        if !row.editedOnPhone, let envelope = try? Data(contentsOf: dir.appendingPathComponent(Self.envelopeName)) {
            return envelope
        }
        return fileBytes(id: id)
    }

    func provenance(id: String) -> AddOnOrigin? { record(id: id)?.origin }

    /// Re-resolve every signature on next use — after an organisation profile arrives or leaves.
    func refreshTrust() { cache.removeAll() }

    // MARK: - Writes

    /// Install a new add-on, or replace an installed one with a newer version. The sheet is the
    /// caller's: this writes only what admission produced and the wearer accepted. An update keeps
    /// the add-on switched on and keeps nothing of the old file.
    @discardableResult
    func install(_ candidate: AddOnCandidate, origin: AddOnOrigin,
                 now: Date = Date()) -> Result<InstalledAddOn, StoreError> {
        guard savingAllowed else { return .failure(.unreadable) }
        let manifest = candidate.manifest
        guard RecipeAddOnValidator.isValidID(manifest.id), let dir = addOnDirectory(manifest.id) else {
            return .failure(.invalidID)
        }
        let existing = installed.firstIndex { $0.id == manifest.id }
        if let existing, !AddOnVersion.isNewer(manifest.version, than: installed[existing].version) {
            return .failure(.notNewer(installed: installed[existing].version))
        }
        guard write(candidate, to: dir) else { return .failure(.writeFailed) }

        let row = InstalledAddOn(
            id: manifest.id, version: manifest.version, name: manifest.name,
            summary: manifest.description, icon: manifest.icon, enabled: true,
            trustAtInstall: StoredTrust(candidate.trust), editedOnPhone: false,
            installedAt: existing.map { installed[$0].installedAt } ?? now, updatedAt: now,
            origin: origin, skillNames: manifest.skills.map(\.name))
        if let existing { installed[existing] = row } else { installed.append(row) }
        cache[manifest.id] = nil
        save()
        PrivacyLog.transfer(.addOn, .installed, item: PrivateIdentifier(manifest.id),
                            version: PrivacyToken(manifest.version), signed: candidate.trust.isSigned,
                            count: manifest.skills.count)
        return .success(row)
    }

    /// Save a source edit the wearer made (and, if it grew, approved). The signature goes; the
    /// version is whatever the edited file says, and the record is marked edited.
    @discardableResult
    func saveEdit(_ candidate: AddOnCandidate, now: Date = Date()) -> Result<InstalledAddOn, StoreError> {
        guard savingAllowed else { return .failure(.unreadable) }
        let manifest = candidate.manifest
        guard let index = installed.firstIndex(where: { $0.id == manifest.id }) else { return .failure(.notInstalled) }
        guard let dir = addOnDirectory(manifest.id) else { return .failure(.invalidID) }
        let unsigned = AddOnCandidate(manifest: manifest, fileBytes: candidate.fileBytes, envelopeBytes: nil,
                                      trust: .community, signatureFailure: nil)
        guard write(unsigned, to: dir) else { return .failure(.writeFailed) }
        var row = installed[index]
        row.version = manifest.version
        row.name = manifest.name
        row.summary = manifest.description
        row.icon = manifest.icon
        row.trustAtInstall = .community
        row.editedOnPhone = true
        row.updatedAt = now
        row.skillNames = manifest.skills.map(\.name)
        installed[index] = row
        cache[manifest.id] = nil
        save()
        PrivacyLog.transfer(.addOn, .imported, item: PrivateIdentifier(manifest.id),
                            version: PrivacyToken(manifest.version), signed: false,
                            count: manifest.skills.count)
        return .success(row)
    }

    /// The per-add-on switch: off, its skills leave the model's tool list on the next rebuild.
    func setEnabled(_ enabled: Bool, id: String) {
        guard savingAllowed, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        cache[id] = nil
        save()
    }

    /// Remove one add-on: its record and its whole directory.
    func remove(id: String) {
        guard savingAllowed, installed.contains(where: { $0.id == id }) else { return }
        installed.removeAll { $0.id == id }
        cache[id] = nil
        if let dir = addOnDirectory(id) { try? FileManager.default.removeItem(at: dir) }
        save()
        PrivacyLog.transfer(.addOn, .removed, item: PrivateIdentifier(id))
    }

    /// Remove every add-on and the folder that held them.
    func removeAll() {
        guard savingAllowed else { return }
        let count = installed.count
        installed = []
        cache.removeAll()
        try? FileManager.default.removeItem(at: directory)
        save()
        PrivacyLog.transfer(.addOn, .removed, count: count)
    }

    // MARK: - Private

    private func addOnDirectory(_ id: String) -> URL? {
        guard RecipeAddOnValidator.isValidID(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    private func write(_ candidate: AddOnCandidate, to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try candidate.fileBytes.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
            let envelopeURL = dir.appendingPathComponent(Self.envelopeName)
            if let envelope = candidate.envelopeBytes {
                try envelope.write(to: envelopeURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: envelopeURL.path) {
                try FileManager.default.removeItem(at: envelopeURL)
            }
            return true
        } catch {
            PrivacyLog.store(.addOns, .writeFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    private func resolveTrust(id: String, fileBytes: Data, editedOnPhone: Bool) -> AddOnTrustClass {
        guard !editedOnPhone, let dir = addOnDirectory(id),
              let envelope = try? Data(contentsOf: dir.appendingPathComponent(Self.envelopeName)) else {
            return .community
        }
        let keys = trustKeys()
        guard let resolution = try? AddOnSignature.resolve(envelope, vendorKeys: keys.vendorKeys,
                                                           trustedOrganisations: keys.trustedOrganisations),
              resolution.fileBytes == fileBytes else {
            return .community
        }
        return resolution.trust
    }

    private func load() {
        switch JSONStore.loadArray(InstalledAddOn.self, at: stateURL, name: "addons",
                                         backupDirectory: backupDirectory) {
        case .loaded(let rows), .recovered(let rows, _):
            installed = rows
        case .absent, .corrupt:
            installed = []   // a corrupt blob was backed up by JSONStore; start fresh on the next change
        case .unreadable:
            installed = []
            savingAllowed = false
        }
    }

    private func save() {
        guard savingAllowed else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(installed)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            PrivacyLog.store(.addOns, .saveFailed, error: SafeErrorSummary(error))
        }
    }
}
