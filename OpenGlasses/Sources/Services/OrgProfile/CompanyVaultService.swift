import Combine
import Foundation

/// Why a company vault pass runs.
enum CompanyVaultSyncReason: Equatable, Sendable {
    /// After every profile renewal attempt: launch and every foreground. Re-reads the vault list
    /// each time, so an upload reaches a bound phone the next time the app comes forward rather
    /// than at its next daily profile renewal. A failed re-read keeps the list already verified,
    /// unless the profile names a newer one.
    case routine
    /// The profile was just applied (an activation key, a profile link or office commissioning):
    /// fetch the vault list at once, so a phone bound in the same visit starts downloading without
    /// waiting to be backgrounded and brought back.
    case enrolled
    /// *Check for Updates*: fetch the vault list whatever its generation.
    case checkForUpdates
    /// The job that held a change closed.
    case jobClosed
    /// The technician tapped *Download now* on a vault whose manuals wait for Wi-Fi.
    case downloadNow
}

/// A company manual that arrived, verified and opened, waiting for its vault.
struct StagedCompanyManual {
    let manual: CompanyVaultCatalog.Manual
    /// The plaintext, in protected staging.
    let file: URL
    let staged: StagedVaultArchive
}

/// What installing, re-laying and removing a company vault does to the phone. Live:
/// `LiveCompanyVaultInstaller`; the tests use an in-memory phone.
@MainActor
protocol CompanyVaultInstalling: AnyObject {
    /// The pack id and version installed for `vaultId`, or nil.
    func installedPack(vaultId: String) -> CompanyVaultPlan.InstalledVault?
    /// Install or update a vault's core files, keeping every manual it holds. Nil, or why it failed.
    func install(_ vault: CompanyVaultCatalog.Vault, fetch: @escaping (URL) async throws -> Data,
                 publicKeyBase64: String, currentBuild: Int) async -> String?
    /// Take manuals out of a vault and put opened ones in, then index what changed.
    func applyManuals(vaultId: String, adding: [StagedCompanyManual], removing: Set<String>) async throws
    func uninstall(vaultId: String) async
}

/// Plan LR P1 — the company vault pass: fetch and verify the company's vault list, plan, and carry
/// the plan out, one vault and one manual file at a time.
///
/// - **Vaults first**, on any network, through `VaultPackCatalogService` with the company catalog's
///   row and the pack key — the EG install path, unchanged, with the vault's manuals kept.
/// - **Then manuals**, each downloaded into protected staging, checked against `sealedSha256`,
///   opened with the company secret, checked against `revision` and laid into its vault with the
///   manuals it already holds (`VaultDocumentCarry`), then indexed on the phone.
/// - **Never mid-job**: what would change a vault the open job uses waits, and the pass runs again
///   when the job closes. **Wi-Fi** for manuals unless the company allows any network or the
///   technician taps Download now. **Space**: a download needs its size twice plus 1 GB free.
/// - Failures are named on the vault's row and tried again at launch and foreground.
///
/// Nothing here leaves the phone but the requests for the list, the packs and the manuals; the
/// manuals themselves never leave it (Plan FS).
@MainActor
final class CompanyVaultService: ObservableObject {

    struct Seams {
        var manager: @MainActor () -> OrgProfileManager = { .shared }
        var fetchCatalog: (URL) async throws -> Data = CompanyVaultService.boundedCatalogFetch
        /// Download to a staged file of exactly `bytes` at most.
        var download: (URL, Int, VaultLinkStagingStore) async throws -> StagedVaultArchive = CompanyVaultService.boundedDownload
        var publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64
        var companySecret: () -> Data? = { CompanySecretStore.device.read() }
        var currentBuild: () -> Int = { Int(AppBuildIdentity.current.build) ?? 0 }
        var network: @MainActor () -> CompanyVaultPlan.Network = {
            (AppStateProvider.shared?.reachability.isExpensive ?? false) ? .metered : .unmetered
        }
        var freeBytes: () -> Int64 = CompanyVaultService.availableBytes
        var activeJob: @MainActor () -> CompanyVaultPlan.Job = {
            FieldSessionService.shared.activeSession.map { .open(vaultId: $0.vaultId) } ?? CompanyVaultPlan.Job.none
        }
        var now: () -> Date = Date.init
        var staging: () -> VaultLinkStagingStore = { .companyVaults() }
        var vaults: @MainActor () -> CompanyVaultInstalling = { LiveCompanyVaultInstaller.shared }
    }

    static let shared = CompanyVaultService()

    var seams: Seams
    private var running = false
    private var again: CompanyVaultSyncReason?
    /// Vaults whose manuals may use cellular for the next pass only (Download now). Not stored:
    /// the consent is for one download, not for the phone.
    private var cellularOnce: Set<String> = []
    private var jobObservation: AnyCancellable?

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Sweep staging left by a pass the app did not finish, and run again whenever a job closes.
    func startAtLaunch() {
        seams.staging().removeAbandonedSessions()
        jobObservation = FieldSessionService.shared.$activeSession
            .map { $0 == nil }
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in Task { @MainActor in await self?.sync(.jobClosed) } }
    }

    /// The rows under *Managed by ⟨org⟩*.
    func rows() -> [CompanyVaultRow] {
        let manager = seams.manager()
        guard let profile = manager.profile, profile.companyVaults != nil, let record = manager.record,
              let state = record.companyVaults else { return [] }
        return CompanyVaultRow.rows(state: state, catalog: verifiedCatalog(state, profile: profile))
    }

    /// The whole-list problem, when there is one.
    func listProblem() -> String? {
        seams.manager().record?.companyVaults?.failures[CompanyVaultState.catalogFailureKey]
    }

    /// *Download now* on a vault whose manuals wait for Wi-Fi: cellular, this once.
    func downloadNow(_ vaultId: String) async {
        cellularOnce.insert(vaultId)
        await sync(.downloadNow)
    }

    /// One pass at a time; a reason that arrives during one runs straight after it.
    func sync(_ reason: CompanyVaultSyncReason) async {
        if running {
            again = again == .checkForUpdates ? again : reason
            return
        }
        running = true
        var next: CompanyVaultSyncReason? = reason
        while let run = next {
            again = nil
            await syncOnce(run)
            next = again
        }
        running = false
    }

    // MARK: - One pass

    private func syncOnce(_ reason: CompanyVaultSyncReason) async {
        let manager = seams.manager()
        guard let profile = manager.profile, let record = manager.record, record.revoked != true,
              record.lapseErasedAt == nil, !manager.contentLocked,
              let pointer = profile.companyVaults else { return }
        let enrolmentId = record.enrolmentId
        var state = record.companyVaults ?? CompanyVaultState()
        let generation = pointer.generation ?? 0
        let verifiedBefore = state.highWater ?? 0
        let moved = generation > verifiedBefore
        func save() { manager.saveCompanyVaults(state, enrolmentId: enrolmentId) }

        guard let url = pointer.catalogURL, generation >= 1 else {
            state.failures[CompanyVaultState.catalogFailureKey] = String(localized: "Your organisation's vault list can't be read by this phone.")
            return save()
        }
        let build = seams.currentBuild()
        if let minimum = pointer.minAppBuild, build < minimum {
            state.failures[CompanyVaultState.catalogFailureKey] =
                String(localized: "Your organisation's vaults need a newer version of the app (build \(minimum) or later).")
            return save()
        }

        // Read the list on launch, every foreground, an enrolment and Check for Updates; a job
        // closing or Download now works from the list already verified unless the profile names a
        // newer one or none is kept. The verifier takes a list newer than the profile's pointer, so
        // an upload arrives without waiting for the daily profile renewal.
        var envelope = state.catalog
        let reads = moved || envelope == nil || reason == .routine || reason == .enrolled || reason == .checkForUpdates
        if reads {
            do {
                envelope = try await seams.fetchCatalog(url)
                state.lastCheckedAt = seams.now()
            } catch {
                // A foreground's re-read that fails (no signal, the host down) is not news: the
                // profile names nothing newer, so the verified list carries on, and any work it
                // still owes continues. Only a missing or behind list is named.
                if envelope == nil || moved || reason == .checkForUpdates {
                    state.failures[CompanyVaultState.catalogFailureKey] =
                        String(localized: "Couldn't reach your organisation's vault list. It tries again when the app opens.")
                    return save()
                }
            }
        }
        guard let envelope else { return }
        let catalog: CompanyVaultCatalog.Verified
        switch CompanyVaultCatalog.verify(envelope, publicKeyBase64: seams.publicKeyBase64, profileId: profile.profileId,
                                          highWater: state.highWater, profileGeneration: generation) {
        case .success(let verified):
            catalog = verified
        case .failure(let refusal):
            state.failures[CompanyVaultState.catalogFailureKey] = refusal.explanation
            return save()
        }
        // The phone may have left or re-enrolled while the list was on its way.
        guard manager.record?.enrolmentId == enrolmentId else { return }
        state.catalog = envelope
        state.highWater = max(state.highWater ?? 0, catalog.generation)
        state.failures[CompanyVaultState.catalogFailureKey] = nil
        if moved || catalog.generation > verifiedBefore { state.removedNames = [] }

        let installer = seams.vaults()
        // What is recorded must still be on the phone: a vault deleted by hand is installed again.
        for vaultId in state.vaults.keys where installer.installedPack(vaultId: vaultId) == nil {
            state.vaults[vaultId] = nil
            state.manuals[vaultId] = nil
        }

        let conditions = CompanyVaultPlan.Conditions(
            job: seams.activeJob(), network: seams.network(), downloadNow: cellularOnce,
            freeBytes: seams.freeBytes(), currentBuild: build, minAppBuild: pointer.minAppBuild)
        let steps = CompanyVaultPlan.steps(installed: state.installed, catalog: catalog, conditions: conditions)
        state.waits = [:]
        for vaultId in Array(state.failures.keys) where vaultId != CompanyVaultState.catalogFailureKey {
            state.failures[vaultId] = nil
        }
        for (vaultId, problem) in catalog.problems { state.failures[vaultId] = problem }
        noteDownloading(&state, catalog: catalog)
        save()

        var manualWork: [String: (adding: [CompanyVaultCatalog.Manual], removing: Set<String>)] = [:]
        var manualOrder: [String] = []
        for step in steps {
            switch step {
            case .needsNewerApp(nil, let minimum):
                state.failures[CompanyVaultState.catalogFailureKey] =
                    String(localized: "Your organisation's vaults need a newer version of the app (build \(minimum) or later).")
            case .needsNewerApp(let vaultId?, let minimum):
                state.waits[vaultId] = .newerApp(build: minimum)
            case .waitForJob(let vaultId, let version, let removal):
                state.waits[vaultId] = .job(version: version, removal: removal)
            case .waitForWiFi(let vaultId, let bytes):
                state.waits[vaultId] = .wifi(bytes: bytes)
            case .notEnoughSpace(let vaultId, let shortfall):
                state.waits[vaultId] = .space(shortfall: shortfall)
            case .remove(let vaultId):
                let name = state.vaults[vaultId]?.name ?? vaultId
                await installer.uninstall(vaultId: vaultId)
                state.vaults[vaultId] = nil
                state.manuals[vaultId] = nil
                state.downloading[vaultId] = nil
                state.removedNames.append(name)
            case .install(let vault), .update(let vault, _):
                let staging = seams.staging()
                let download = seams.download
                let fetch: (URL) async throws -> Data = { url in
                    let staged = try await download(url, vault.sizeBytes, staging)
                    defer { staging.remove(staged) }
                    // Mapped, then unlinked: the mapping outlives the file, and the pack is never
                    // held twice in memory.
                    return try staging.load(staged)
                }
                if let failure = await installer.install(vault, fetch: fetch, publicKeyBase64: seams.publicKeyBase64,
                                                         currentBuild: build) {
                    state.failures[vault.vaultId] = String(localized: "Couldn't install \(vault.name): \(failure).")
                } else {
                    state.vaults[vault.vaultId] = .init(packId: vault.id, name: vault.name, version: vault.version,
                                                        updatedAt: seams.now())
                }
            case .addManual(let manual), .replaceManual(let manual, _):
                if manualWork[manual.vaultId] == nil { manualOrder.append(manual.vaultId) }
                manualWork[manual.vaultId, default: ([], [])].adding.append(manual)
            case .removeManual(let vaultId, let fileName):
                if manualWork[vaultId] == nil { manualOrder.append(vaultId) }
                manualWork[vaultId, default: ([], [])].removing.insert(fileName)
            }
            save()
        }

        for vaultId in manualOrder {
            guard let work = manualWork[vaultId], state.vaults[vaultId] != nil else { continue }
            await applyManuals(vaultId: vaultId, work: work, profileId: profile.profileId, state: &state,
                               installer: installer)
            noteDownloading(&state, catalog: catalog)
            save()
        }
        cellularOnce = []
        noteDownloading(&state, catalog: catalog)
        if state.waits.isEmpty, state.failures.isEmpty { state.appliedGeneration = catalog.generation }
        save()
    }

    /// Download, check and open each file, then lay the ones that arrived into the vault together.
    private func applyManuals(vaultId: String, work: (adding: [CompanyVaultCatalog.Manual], removing: Set<String>),
                              profileId: String, state: inout CompanyVaultState, installer: CompanyVaultInstalling) async {
        let staging = seams.staging()
        var staged: [StagedCompanyManual] = []
        defer { for item in staged { staging.remove(item.staged) } }
        var failures: [String] = []
        if !work.adding.isEmpty {
            guard let secret = seams.companySecret(), secret.count == OrgCredentialSeal.secretLength else {
                state.failures[vaultId] = String(localized: "The manuals can't be opened on this phone. Enter your company's activation key again.")
                return
            }
            for manual in work.adding {
                do {
                    staged.append(try await stage(manual, profileId: profileId, secret: secret, staging: staging))
                } catch {
                    failures.append(Self.reason(error, manual: manual))
                }
            }
        }
        guard !staged.isEmpty || !work.removing.isEmpty else {
            state.failures[vaultId] = failures.first
            return
        }
        do {
            try await installer.applyManuals(vaultId: vaultId, adding: staged, removing: work.removing)
            var installed = state.manuals[vaultId] ?? [:]
            for name in work.removing { installed[name] = nil }
            for item in staged { installed[item.manual.fileName] = item.manual.revision }
            state.manuals[vaultId] = installed
            state.vaults[vaultId]?.updatedAt = seams.now()
            state.failures[vaultId] = failures.first
        } catch {
            let name = state.vaults[vaultId]?.name ?? vaultId
            state.failures[vaultId] = String(localized: "Couldn't add the new manuals to \(name). It tries again when the app opens.")
        }
    }

    /// One manual: download → `sealedSha256` → open with the company secret → `revision`.
    private func stage(_ manual: CompanyVaultCatalog.Manual, profileId: String, secret: Data,
                       staging: VaultLinkStagingStore) async throws -> StagedCompanyManual {
        guard let url = CompanyVaultCatalog.downloadURL(manual.downloadURL) else { throw CompanyManualSeal.Failure.malformed }
        let expected = CompanyManualSeal.sealedLength(plaintextBytes: manual.sizeBytes)
        let sealed = try await seams.download(url, expected, staging)
        defer { staging.remove(sealed) }
        let size = (try? FileManager.default.attributesOfItem(atPath: sealed.fileURL.path)[.size] as? NSNumber)?.intValue
        guard size == expected else { throw CompanyManualSeal.Failure.malformed }
        guard try CompanyManualSeal.fileDigest(sealed.fileURL) == manual.sealedSha256 else {
            throw CompanyManualSeal.Failure.tampered
        }
        let plain = try staging.create()
        do {
            let handle = try FileHandle(forReadingFrom: sealed.fileURL)
            defer { try? handle.close() }
            let opened = try CompanyManualSeal.open(
                length: expected,
                read: { range in
                    try handle.seek(toOffset: UInt64(range.lowerBound))
                    return try handle.read(upToCount: range.count) ?? Data()
                },
                context: .init(profileId: profileId, manual: manual), companySecret: secret,
                sink: { try staging.append($0, to: plain) })
            guard opened == manual.sizeBytes else { throw CompanyManualSeal.Failure.wrongRevision }
        } catch {
            staging.remove(plain)
            throw error
        }
        return StagedCompanyManual(manual: manual, file: plain.fileURL, staged: plain)
    }

    /// What is listed for each vault and not yet here, by title: the rows say "Downloading" and an
    /// answer that would cite one says it is still on its way.
    private func noteDownloading(_ state: inout CompanyVaultState, catalog: CompanyVaultCatalog.Verified) {
        var downloading: [String: [String]] = [:]
        for vault in catalog.vaults {
            let have = state.manuals[vault.vaultId] ?? [:]
            let missing = catalog.manuals(in: vault.vaultId).filter { have[$0.fileName] == nil }.map(\.title)
            if !missing.isEmpty { downloading[vault.vaultId] = missing }
        }
        state.downloading = downloading
    }

    private func verifiedCatalog(_ state: CompanyVaultState, profile: ConfigProfile) -> CompanyVaultCatalog.Verified? {
        guard let envelope = state.catalog else { return nil }
        return try? CompanyVaultCatalog.verify(envelope, publicKeyBase64: seams.publicKeyBase64, profileId: profile.profileId,
                                               highWater: nil, profileGeneration: 0).get()
    }

    /// Why one manual did not arrive, in words for its vault's row.
    static func reason(_ error: Error, manual: CompanyVaultCatalog.Manual) -> String {
        switch error {
        case CompanyManualSeal.Failure.tampered, CompanyManualSeal.Failure.wrongRevision:
            return String(localized: "\(manual.title) doesn't match your organisation's vault list, so it was refused.")
        case CompanyManualSeal.Failure.noSecret:
            return String(localized: "\(manual.title) can't be opened on this phone. Enter your company's activation key again.")
        case CompanyManualSeal.Failure.malformed, VaultLinkStagingError.tooLarge:
            return String(localized: "\(manual.title) didn't arrive whole. It tries again when the app opens.")
        default:
            return String(localized: "Couldn't download \(manual.title). It tries again when the app opens.")
        }
    }

    // MARK: - Production transport

    /// The vault list: a signed JSON document from the address the vendor-signed profile names.
    /// Fetched through the shared hardened client like the profile itself, and treated as the
    /// profile fetch is under Medical Local Only: it carries nothing of the phone's.
    nonisolated static func boundedCatalogFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await BoundedHTTPClient().fetchData(url, profile: .companyVaultCatalog)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    /// A pack or a sealed manual, straight into protected staging, never more than `bytes`.
    nonisolated static func boundedDownload(_ url: URL, bytes: Int, staging: VaultLinkStagingStore) async throws -> StagedVaultArchive {
        let archive = try staging.create()
        do {
            var received = 0
            let response = try await BoundedHTTPClient().fetch(url, profile: .companyVaultFile(maximumBytes: bytes)) { chunk in
                received += chunk.count
                guard received <= bytes else { throw VaultLinkStagingError.tooLarge }
                try staging.append(chunk, to: archive)
            }
            guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            return archive
        } catch {
            staging.remove(archive)
            throw error
        }
    }

    nonisolated static func availableBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension BoundedHTTPClient.Profile {
    /// The company vault list (Plan LR): signed JSON, a few kilobytes to a megabyte.
    static let companyVaultCatalog = BoundedHTTPClient.Profile(
        name: "companyVaultCatalog",
        maximumBytes: CompanyVaultCatalog.maximumEnvelopeBytes,
        acceptedMIMETypes: ["application/json", "text/plain", "application/octet-stream"],
        maximumRedirects: 3,
        allowsPrivateHTTP: false,
        totalTimeout: 20,
        firstByteTimeout: 8,
        idleTimeout: 5)

    /// A company vault pack or a sealed manual (Plan LR): up to a few hundred megabytes from the
    /// licence service's storage, sized for a long transfer on a phone connection.
    static func companyVaultFile(maximumBytes: Int) -> BoundedHTTPClient.Profile {
        BoundedHTTPClient.Profile(
            name: "companyVaultFile",
            maximumBytes: maximumBytes,
            acceptedMIMETypes: ["application/octet-stream", "binary/octet-stream", "application/zip",
                                "application/x-zip-compressed"],
            maximumRedirects: 3,
            allowsPrivateHTTP: false,
            totalTimeout: 1_800,
            firstByteTimeout: 15,
            idleTimeout: 30)
    }
}

/// The live installer: the EG pack path for core files, `VaultDocumentCarry` for manuals, and the
/// importer's own indexing and uninstall.
@MainActor
final class LiveCompanyVaultInstaller: CompanyVaultInstalling {
    static let shared = LiveCompanyVaultInstaller()

    func installedPack(vaultId: String) -> CompanyVaultPlan.InstalledVault? {
        VaultImporter.installedPack(for: vaultId).map { .init(packId: $0.id, version: $0.version) }
    }

    func install(_ vault: CompanyVaultCatalog.Vault, fetch: @escaping (URL) async throws -> Data,
                 publicKeyBase64: String, currentBuild: Int) async -> String? {
        let service = VaultPackCatalogService(catalogURL: { nil }, fetch: fetch, publicKeyBase64: publicKeyBase64,
                                              currentBuild: currentBuild)
        await service.install(vault.entry, keeping: VaultDocumentCarry.current(vaultId: vault.vaultId))
        switch service.installStates[vault.id] {
        case .installed?: return nil
        case .failed(let reason)?: return reason
        default: return String(localized: "it did not finish installing")
        }
    }

    func applyManuals(vaultId: String, adding: [StagedCompanyManual], removing: Set<String>) async throws {
        var kept: [VaultDocumentCarry.Kept] = []
        var prepared: [ManualFileUpload.Prepared] = []
        let fm = FileManager.default
        let named = fm.temporaryDirectory.appendingPathComponent("CompanyManual-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: named, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        defer {
            try? fm.removeItem(at: named)
            for item in prepared { item.discard() }
        }
        for item in adding {
            let manual = item.manual
            let document = VaultDocument(file: manual.fileName, title: manual.title, kind: "company_manual")
            switch manual.kind {
            case .pdf, .md:
                kept.append(.init(document: document, files: [manual.fileName: item.file]))
            case .docx:
                // A Word manual keeps its original beside a text reading copy for page citations,
                // as an uploaded one does.
                let original = named.appendingPathComponent(manual.fileName)
                try fm.copyItem(at: item.file, to: original)
                let copy = try await Task.detached(priority: .utility) { try ManualFileUpload.prepare(original) }.value
                prepared.append(copy)
                let reading = manual.fileName + ".reading.pdf"
                kept.append(.init(document: VaultDocument(file: manual.fileName, title: manual.title, kind: "company_manual",
                                                          source: reading, personalReadingCopy: true),
                                  files: [manual.fileName: copy.original, reading: copy.readingPDF]))
            }
        }
        let manifest = try await VaultOperationLock.withLock(vaultId) {
            try VaultDocumentCarry.relay(vaultId: vaultId, removing: removing, adding: kept)
        }
        if let store = AppStateProvider.shared?.documentStore {
            _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        }
    }

    func uninstall(vaultId: String) async {
        if let store = AppStateProvider.shared?.documentStore {
            await VaultImporter.uninstall(id: vaultId, documentStore: store)
        } else {
            VaultImporter.uninstall(id: vaultId)
        }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
    }
}
