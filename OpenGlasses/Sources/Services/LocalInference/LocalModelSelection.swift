import Foundation

/// The selected on-device model, as a stable identity rather than a runtime-specific string
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "The selected local model stored in app
/// configuration becomes a stable `LocalModelID`; the runtime is resolved from the descriptor").
///
/// ### What changes, and what deliberately does not
/// Before this, "the local model" was `ModelConfig.model` — a hub repository id that the MLX path
/// read directly. That string cannot name a GGUF installation: one repository publishes a dozen
/// quantizations and each is a separate install, which is why `LocalModelID.gguf` joins the
/// repository to the file group. So the selection becomes a `LocalModelID` in its own versioned
/// record, and the runtime comes from the *installation record's descriptor* — never from the
/// shape of the string.
///
/// The legacy field stays, and stays synchronized, for one compatibility release. That is the
/// plan's requirement and it has a concrete consequence worth stating: for every model that exists
/// today the id **is** the hub repository id, so an MLX selection writes an identical value into
/// both places and every existing reader of `ModelConfig.model` keeps working unchanged.
///
/// ### The one place the two fields diverge, and why
/// A GGUF selection is not written into the legacy field. A build without this plan has no GGUF
/// runtime; handing it `owner/repo#model-Q4_K_M.gguf` would give it an id it will try to fetch from
/// the MLX hub and fail on, every launch, with no way for the user to tell why. Instead the legacy
/// field keeps the last MLX selection — or is cleared when there has never been one, which leaves
/// the older build in the "no on-device model chosen" state it already handles. That is the
/// downgrade-safety property: **an MLX selection always survives a downgrade, and a GGUF selection
/// never corrupts one.**

/// The persisted selection. Versioned because the *meaning* of the field may change again when the
/// legacy mirror is dropped, and a record whose version is newer than this build understands is
/// ignored rather than half-read.
struct LocalModelSelectionRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var id: LocalModelID
    var updatedAt: Date

    init(id: LocalModelID, updatedAt: Date, version: Int = LocalModelSelectionRecord.currentVersion) {
        self.version = version
        self.id = id
        self.updatedAt = updatedAt
    }
}

/// Reads and writes the selection, with every environment dependency injected so the migration and
/// the synchronization rule are exercised headlessly against in-memory storage.
struct LocalModelSelectionStore: Sendable {

    static let recordKey = "localModelSelection"
    /// Forward-only stamp, in the same shape as the installed-records migration.
    static let migrationVersionKey = "localModelSelectionMigratedVersion"
    static let migrationVersion = 1

    enum MigrationOutcome: Equatable, Sendable {
        /// The stamp is already at or past this version.
        case alreadyMigrated
        /// No legacy selection to carry forward. Stamped anyway: from here on `select` writes both
        /// fields, so nothing can appear later that this migration would have been for.
        case nothingToMigrate
        case migrated(LocalModelID)
        /// The record did not read back as written. Nothing is stamped; the next launch retries.
        case readBackFailed
    }

    let defaults: UserDefaults
    /// The legacy string field — `ModelConfig.model` for the on-device provider, in production.
    let legacySelection: @Sendable () -> String
    let setLegacySelection: @Sendable (String) -> Void
    /// Which runtime an id belongs to, resolved from the installation record's descriptor. Falls
    /// back to `.mlx` for an id nothing knows about, because MLX is the only runtime that could
    /// have produced an installation before this plan.
    let runtimeForID: @Sendable (LocalModelID) -> LocalModelRuntime
    let now: @Sendable () -> Date

    init(defaults: UserDefaults = .standard,
         legacySelection: @escaping @Sendable () -> String,
         setLegacySelection: @escaping @Sendable (String) -> Void,
         runtimeForID: @escaping @Sendable (LocalModelID) -> LocalModelRuntime,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.legacySelection = legacySelection
        self.setLegacySelection = setLegacySelection
        self.runtimeForID = runtimeForID
        self.now = now
    }

    // MARK: - Reading

    /// The stored record, or nil when there is none or it was written by a newer build.
    func record() -> LocalModelSelectionRecord? {
        guard let data = defaults.data(forKey: Self.recordKey),
              let decoded = try? Self.decoder.decode(LocalModelSelectionRecord.self, from: data),
              decoded.version <= LocalModelSelectionRecord.currentVersion,
              !decoded.id.rawValue.isEmpty else { return nil }
        return decoded
    }

    /// The selected id. Falls back to the legacy string, which is what makes a device that has not
    /// run the migration yet — or one whose migration could not write — behave exactly as before.
    func selectedID() -> LocalModelID? {
        if let record = record() { return record.id }
        let legacy = legacySelection().trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy.isEmpty ? nil : LocalModelID(legacy)
    }

    // MARK: - Writing

    /// Record a selection and synchronize the legacy field per the rule documented on this file.
    @discardableResult
    func select(_ id: LocalModelID) -> Bool {
        let record = LocalModelSelectionRecord(id: id, updatedAt: now())
        guard let data = try? Self.encoder.encode(record) else { return false }
        defaults.set(data, forKey: Self.recordKey)
        synchronizeLegacyField(for: id)
        // Read back, for the same reason the installed-records migration does: a preferences write
        // that did not land must not be reported as a selection that did.
        return self.record()?.id == id
    }

    /// Forget the selection — used when the selected model is removed, so nothing keeps pointing at
    /// files that are gone.
    func clearSelection() {
        // Read before removing: the legacy field is cleared only when it named the model being
        // forgotten, and after the record is gone there is nothing left to compare it against. An
        // MLX id left there by an earlier selection is still a usable answer for an older build.
        let forgotten = record()?.id
        defaults.removeObject(forKey: Self.recordKey)
        if let forgotten, legacySelection() == forgotten.rawValue {
            setLegacySelection("")
        }
    }

    /// The synchronization rule. Its whole content is the divergence documented above.
    private func synchronizeLegacyField(for id: LocalModelID) {
        switch runtimeForID(id) {
        case .mlx:
            setLegacySelection(id.rawValue)
        case .llamaCpp:
            // Leave a usable MLX id in place; clear anything else so an older build is never handed
            // an id it cannot fetch.
            let legacy = legacySelection().trimmingCharacters(in: .whitespacesAndNewlines)
            if legacy.isEmpty { return }
            if runtimeForID(LocalModelID(legacy)) != .mlx { setLegacySelection("") }
        }
    }

    // MARK: - Migration

    /// Carry the legacy string forward into a record. Forward-only, idempotent, and stamped only
    /// after the written record reads back identical.
    @discardableResult
    func migrateIfNeeded() -> MigrationOutcome {
        guard defaults.integer(forKey: Self.migrationVersionKey) < Self.migrationVersion else {
            return .alreadyMigrated
        }
        // A record already present means a newer build wrote one before this migration ran. Stamp
        // and leave it alone rather than overwriting a deliberate selection with a stale string.
        if record() != nil {
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            return .alreadyMigrated
        }

        let legacy = legacySelection().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else {
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            return .nothingToMigrate
        }

        let id = LocalModelID(legacy)
        let record = LocalModelSelectionRecord(id: id, updatedAt: now())
        guard let data = try? Self.encoder.encode(record) else { return .readBackFailed }
        defaults.set(data, forKey: Self.recordKey)
        guard self.record()?.id == id else { return .readBackFailed }
        // The legacy field is untouched by the migration: it already holds this value, and writing
        // it back would be a Keychain write with nothing to change.
        defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
        PrivacyLog.localModel(.recordsMigrated, count: 1, detail: PrivacyToken("selection"))
        return .migrated(id)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - App wiring

/// The production store and the lookups it needs. Separate from `LocalModelSelectionStore` so the
/// store itself never has to know about the Keychain, the repository, or the catalog.
enum LocalModelSelection {

    /// The legacy field: the on-device provider's `model` string in the saved model configurations.
    static func legacyModelString() -> String {
        Config.savedModels.first { $0.llmProvider == .local }?.model ?? ""
    }

    static func setLegacyModelString(_ value: String) {
        var models = Config.savedModels
        guard let index = models.firstIndex(where: { $0.llmProvider == .local }) else { return }
        guard models[index].model != value else { return }
        models[index].model = value
        Config.setSavedModels(models)
    }

    /// Runtime from the descriptor, in the order of increasing guesswork: the installation record
    /// first (it is a fact about files on disk), then the bundled GGUF catalog (an entry that could
    /// be installed), then MLX.
    static func runtime(for id: LocalModelID,
                        repository: LocalModelRepository = LocalModelRepository()) -> LocalModelRuntime {
        if let installation = repository.installation(for: id) { return installation.runtime }
        if LocalModelCatalog.bundledGGUFEntries().contains(where: { $0.id == id }) { return .llamaCpp }
        return .mlx
    }

    static func store(repository: LocalModelRepository = LocalModelRepository()) -> LocalModelSelectionStore {
        LocalModelSelectionStore(
            legacySelection: { legacyModelString() },
            setLegacySelection: { setLegacyModelString($0) },
            runtimeForID: { runtime(for: $0, repository: repository) })
    }

    /// Resolve the installation a load should be given for an id.
    ///
    /// This is the "runtime is resolved from the descriptor" half of the migration: an installed
    /// model answers with its own record — real runtime, real storage, real revision — and anything
    /// else falls back to the MLX compatibility installation the seam has always synthesized, so a
    /// model the repository has no record of behaves exactly as it did before.
    static func installation(for id: LocalModelID,
                             repository: LocalModelRepository = LocalModelRepository())
        -> InstalledLocalModel {
        if let installation = repository.installation(for: id) { return installation }
        return compatibilityInstallation(for: id)
    }

    /// The MLX compatibility installation the seam has always synthesized for an id with no record.
    static func compatibilityInstallation(for id: LocalModelID) -> InstalledLocalModel {
        InstalledLocalModel(
            descriptor: LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: id.rawValue),
            storage: .legacyHubSnapshot(
                directoryName: LocalModelRepository.legacyDirectoryName(forModelID: id.rawValue)),
            installedAt: Date(timeIntervalSince1970: 0))
    }
}
