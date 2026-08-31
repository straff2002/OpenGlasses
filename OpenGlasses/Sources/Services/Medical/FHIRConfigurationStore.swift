import Foundation

/// Owns the split FHIR setup: public metadata in preferences, credentials and clinical
/// identifiers in protected storage, and the one-time migration off the legacy combined blob.
///
/// The migration is forward-only. Once a device has moved, the legacy preference key is gone and
/// nothing writes it again — a rolled-back build reads the protected stores or reads nothing.
final class FHIRConfigurationStore {
    static let shared = FHIRConfigurationStore()

    /// Preference key holding ``FHIRServerConfiguration`` — public metadata only.
    static let configurationKey = "fhirServerConfiguration"
    /// Legacy key holding the combined blob (endpoint, token, client secret, patient and
    /// practitioner ids). Only the migration reads it, and only until it has verified the move.
    static let legacyConfigurationKey = "fhirConfig"
    /// Versioned so a later split (a second server, a refresh token) can migrate again.
    static let migrationVersionKey = "fhirSecretsMigratedVersion"
    static let migrationVersion = 1

    enum MigrationOutcome: Equatable {
        /// Nothing to move, or already moved.
        case notNeeded
        /// Values moved, verified, and the legacy key removed.
        case migrated
        /// Protected storage was unavailable (device locked). Retried on the next launch;
        /// FHIR sends stay blocked until it succeeds.
        case deferred
        /// Write or read-back verification failed. The legacy value is retained for the retry and
        /// is never used for a network request.
        case failed
    }

    private let defaults: UserDefaults
    private let credentials: FHIRCredentialStore
    private let contexts: FHIRPrivateContextStore

    init(defaults: UserDefaults = .standard,
         credentials: FHIRCredentialStore = KeychainFHIRSecretStore(),
         contexts: FHIRPrivateContextStore = KeychainFHIRSecretStore()) {
        self.defaults = defaults
        self.credentials = credentials
        self.contexts = contexts
    }

    // MARK: - Public configuration

    /// The stored public configuration.
    ///
    /// A first read mints the server id *and persists it at once*. Every protected value is keyed
    /// by that id, so two reads must never disagree — returning an unsaved fresh id would file the
    /// credential under one server and look for it under another.
    var configuration: FHIRServerConfiguration {
        if let data = defaults.data(forKey: Self.configurationKey),
           let config = try? JSONDecoder().decode(FHIRServerConfiguration.self, from: data) {
            return config
        }
        let fresh = FHIRServerConfiguration()
        save(fresh)
        return fresh
    }

    func save(_ configuration: FHIRServerConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }

    /// True while a legacy blob is still on disk unmigrated. Every FHIR send is blocked in this
    /// state: the only copy of the secret is the one we are about to move, and using it would
    /// undo the "never read the legacy value for a request" rule.
    var isMigrationPending: Bool {
        defaults.integer(forKey: Self.migrationVersionKey) < Self.migrationVersion
            && defaults.data(forKey: Self.legacyConfigurationKey) != nil
    }

    // MARK: - Protected values

    func loadCredential(serverID: String? = nil) throws -> FHIRCredential {
        let id = serverID ?? configuration.serverID
        do {
            return try credentials.load(serverID: id) ?? FHIRCredential()
        } catch KeychainService.KeychainError.unavailable {
            throw MedicalExportError.credentialLocked
        } catch {
            throw MedicalExportError.protectedStorageUnavailable
        }
    }

    func loadPrivateContext(serverID: String? = nil) throws -> FHIRPrivateContext {
        let id = serverID ?? configuration.serverID
        do {
            return try contexts.loadContext(serverID: id) ?? FHIRPrivateContext()
        } catch KeychainService.KeychainError.unavailable {
            throw MedicalExportError.credentialLocked
        } catch {
            throw MedicalExportError.protectedStorageUnavailable
        }
    }

    func storeCredential(_ credential: FHIRCredential, serverID: String? = nil) throws {
        let id = serverID ?? configuration.serverID
        do {
            try credentials.save(credential, serverID: id)
        } catch KeychainService.KeychainError.unavailable {
            throw MedicalExportError.credentialLocked
        } catch {
            throw MedicalExportError.protectedStorageUnavailable
        }
    }

    func storePrivateContext(_ context: FHIRPrivateContext, serverID: String? = nil) throws {
        let id = serverID ?? configuration.serverID
        do {
            try contexts.saveContext(context, serverID: id)
        } catch KeychainService.KeychainError.unavailable {
            throw MedicalExportError.credentialLocked
        } catch {
            throw MedicalExportError.protectedStorageUnavailable
        }
    }

    /// Whether a credential is stored, without decrypting it into anything the UI can render.
    /// Answers "cannot tell right now" as `false` so the settings screen offers Replace rather
    /// than claiming a credential is present.
    func hasStoredCredential(serverID: String? = nil) -> Bool {
        ((try? loadCredential(serverID: serverID))?.isEmpty == false)
    }

    // MARK: - Clearing

    /// Drop the credential only — for an auth-mode change away from secret auth, or a sign out.
    func clearCredential(serverID: String? = nil) {
        try? credentials.delete(serverID: serverID ?? configuration.serverID)
    }

    /// Drop every protected value for a server. Used by server deletion and medical data reset.
    func clearProtectedValues(serverID: String? = nil) {
        let id = serverID ?? configuration.serverID
        try? credentials.delete(serverID: id)
        try? contexts.deleteContext(serverID: id)
    }

    /// Delete a server entirely: protected values first, then the public metadata that addresses
    /// them. In that order, an interruption leaves an orphan preference rather than an orphan
    /// secret.
    func deleteServer() {
        clearProtectedValues()
        defaults.removeObject(forKey: Self.configurationKey)
    }

    /// Apply an auth-mode change, clearing the credential when the new mode has no use for one.
    func applyAuthMode(_ mode: FHIRAuthMode) {
        var config = configuration
        guard config.authMode != mode else { return }
        config.authMode = mode
        save(config)
        if !mode.usesStoredSecret { clearCredential(serverID: config.serverID) }
    }

    // MARK: - Request assembly

    /// Assemble everything one FHIR request needs, or throw the reason it cannot be assembled.
    func requestContext() throws -> FHIRRequestContext {
        if isMigrationPending { throw MedicalExportError.migrationPending }
        let config = configuration
        guard config.isConfigured else { throw MedicalExportError.serverNotConfigured }

        let credential = try loadCredential(serverID: config.serverID)
        if config.authMode.usesStoredSecret && credential.isEmpty {
            throw MedicalExportError.credentialMissing
        }
        let context = try loadPrivateContext(serverID: config.serverID)
        return FHIRRequestContext(configuration: config, credential: credential, privateContext: context)
    }

    // MARK: - Migration

    /// Move a legacy combined blob into the split stores. Idempotent, and safe to call on every
    /// launch: the version stamp is only written once the protected copies have been read back
    /// and compared, so an interrupted run retries rather than losing the only copy.
    @discardableResult
    func migrateIfNeeded() -> MigrationOutcome {
        guard defaults.integer(forKey: Self.migrationVersionKey) < Self.migrationVersion else {
            return .notNeeded
        }
        guard let data = defaults.data(forKey: Self.legacyConfigurationKey) else {
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            return .notNeeded
        }
        guard let legacy = try? JSONDecoder().decode(LegacyFHIRConfiguration.self, from: data) else {
            // An undecodable blob holds nothing we can recover or protect; removing it is the
            // only outcome that leaves no plaintext behind.
            defaults.removeObject(forKey: Self.legacyConfigurationKey)
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            return .notNeeded
        }

        // Take (and persist) the server id before writing anything keyed by it, so a failed
        // attempt and its retry file the protected values under the same id rather than orphaning
        // the first attempt's items.
        let config = FHIRServerConfiguration(
            serverID: configuration.serverID,
            baseURL: legacy.baseURL,
            authMode: legacy.inferredAuthMode,
            clientID: legacy.clientId,
            platformType: legacy.platformType
        )
        let credential = FHIRCredential(bearerToken: legacy.bearerToken, clientSecret: legacy.clientSecret)
        let context = FHIRPrivateContext(patientID: legacy.patientId, practitionerID: legacy.practitionerId)

        do {
            try credentials.save(credential, serverID: config.serverID)
            try contexts.saveContext(context, serverID: config.serverID)

            // Read back before deleting the only copy. A store that accepted a write and cannot
            // return it is a failure, not a migration.
            let storedCredential = try credentials.load(serverID: config.serverID) ?? FHIRCredential()
            let storedContext = try contexts.loadContext(serverID: config.serverID) ?? FHIRPrivateContext()
            guard storedCredential == credential, storedContext == context else {
                NSLog("[MedicalExport] Credential migration verification failed — retrying next launch")
                return .failed
            }

            save(config)
            defaults.removeObject(forKey: Self.legacyConfigurationKey)
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            NSLog("[MedicalExport] Migrated FHIR credentials out of preferences into protected storage")
            return .migrated
        } catch KeychainService.KeychainError.unavailable {
            NSLog("[MedicalExport] Credential migration deferred — protected storage unavailable")
            return .deferred
        } catch {
            NSLog("[MedicalExport] Credential migration failed — retrying next launch")
            return .failed
        }
    }
}

/// The retired combined blob, decoded only by the migration. Field names match the shipped
/// encoding, so they are the legacy spelling rather than the new one.
private struct LegacyFHIRConfiguration: Codable {
    var baseURL: String = ""
    var bearerToken: String = ""
    var clientId: String = ""
    var clientSecret: String = ""
    var patientId: String = ""
    var practitionerId: String = ""
    var platformType: String = MedicalPlatform.fhir.rawValue

    /// The legacy blob had no auth mode — it just used whichever secret was filled in.
    var inferredAuthMode: FHIRAuthMode {
        if !bearerToken.isEmpty { return .bearerToken }
        if !clientSecret.isEmpty || !clientId.isEmpty { return .clientSecret }
        return .none
    }
}
