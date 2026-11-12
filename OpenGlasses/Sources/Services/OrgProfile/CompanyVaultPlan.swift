import Foundation

/// Plan LR — what this phone holds of its company's vaults, kept on the enrolment record
/// (`OrgEnrolmentRecord.companyVaults`) so it is erased with the enrolment and needs no store of
/// its own. Names, versions, hashes and dates; no manual content.
struct CompanyVaultState: Codable, Equatable, Sendable {
    /// One company vault on this phone.
    struct Vault: Codable, Equatable, Sendable {
        var packId: String
        var name: String
        var version: String
        var updatedAt: Date
    }

    /// Why a vault is not yet as the catalog lists it, for its row.
    enum Wait: Codable, Equatable, Sendable {
        /// A change to it waits for the open job to close: the new version, or nil for a removal
        /// or a change to its manuals.
        case job(version: String?, removal: Bool)
        /// Its manuals wait for Wi-Fi: this many bytes.
        case wifi(bytes: Int64)
        /// Not enough space: this much more is needed.
        case space(shortfall: Int64)
        /// It needs a newer build of the app.
        case newerApp(build: Int)
    }

    /// The newest catalog generation verified on this phone: the high-water mark a replayed or
    /// older catalog is refused against.
    var highWater: Int?
    /// The generation whose every step has landed. Below `highWater` while anything waits or failed.
    var appliedGeneration: Int?
    /// The verified catalog envelope, kept as evidence and verified again before each use.
    var catalog: Data?
    /// Company vaults installed here, by vault id.
    var vaults: [String: Vault] = [:]
    /// Company manuals installed here: vault id → file name → revision.
    var manuals: [String: [String: String]] = [:]
    /// The last failure per vault id, named ("" is the catalog as a whole).
    var failures: [String: String] = [:]
    /// What each vault waits for.
    var waits: [String: Wait] = [:]
    /// Titles of manuals listed for a vault that are not on this phone yet.
    var downloading: [String: [String]] = [:]
    /// Vaults the company removed from this phone, by name, for the notice.
    var removedNames: [String] = []
    var lastCheckedAt: Date?

    static let catalogFailureKey = ""

    init() {}

    /// Every field read if present and skipped if not, so a state written by another build can
    /// never stop the enrolment record it lives on from reading.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        highWater = try? c.decodeIfPresent(Int.self, forKey: .highWater)
        appliedGeneration = try? c.decodeIfPresent(Int.self, forKey: .appliedGeneration)
        catalog = try? c.decodeIfPresent(Data.self, forKey: .catalog)
        vaults = (try? c.decodeIfPresent([String: Vault].self, forKey: .vaults)) ?? [:]
        manuals = (try? c.decodeIfPresent([String: [String: String]].self, forKey: .manuals)) ?? [:]
        failures = (try? c.decodeIfPresent([String: String].self, forKey: .failures)) ?? [:]
        waits = (try? c.decodeIfPresent([String: Wait].self, forKey: .waits)) ?? [:]
        downloading = (try? c.decodeIfPresent([String: [String]].self, forKey: .downloading)) ?? [:]
        removedNames = (try? c.decodeIfPresent([String].self, forKey: .removedNames)) ?? []
        lastCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    /// What the plan reads: the vaults and manuals installed, as recorded.
    var installed: CompanyVaultPlan.Installed {
        .init(vaults: vaults.mapValues { .init(packId: $0.packId, version: $0.version) }, manuals: manuals)
    }

    /// Whether a pass has anything left to try without a new generation.
    var hasPendingWork: Bool {
        !failures.isEmpty || !waits.isEmpty || (appliedGeneration ?? 0) < (highWater ?? 0)
    }

    /// After a lapse erasure: nothing is installed any more, so the next pass installs everything.
    mutating func forgetInstalled() {
        vaults = [:]
        manuals = [:]
        appliedGeneration = nil
        waits = [:]
        failures = [:]
        downloading = [:]
    }
}

/// Plan LR P0 — every decision about a company's vaults, pure: what is installed, the verified
/// catalog, whether a job is open and on which vault, the network and the free space in; a list of
/// steps out. The renewal pass (`CompanyVaultService`) carries them out in order.
enum CompanyVaultPlan {

    struct InstalledVault: Equatable, Sendable {
        let packId: String
        let version: String
    }

    struct Installed: Equatable, Sendable {
        var vaults: [String: InstalledVault] = [:]
        /// vault id → file name → revision.
        var manuals: [String: [String: String]] = [:]
    }

    enum Job: Equatable, Sendable {
        case none
        /// A job is open on this vault; nil when it cannot be told, and then every vault counts as
        /// in use.
        case open(vaultId: String?)

        func uses(_ vaultId: String) -> Bool {
            switch self {
            case .none: return false
            case .open(let id): return id == nil || id == vaultId
            }
        }
    }

    enum Network: Equatable, Sendable {
        /// A network the system does not call expensive: Wi-Fi or wired.
        case unmetered
        /// Cellular, or a personal hotspot.
        case metered
    }

    struct Conditions: Equatable, Sendable {
        var job: Job = .none
        var network: Network = .unmetered
        /// Vaults the technician tapped Download now on.
        var downloadNow: Set<String> = []
        var freeBytes: Int64
        var currentBuild: Int
        /// The profile pointer's `minAppBuild`.
        var minAppBuild: Int?
    }

    enum Step: Equatable, Sendable {
        case install(CompanyVaultCatalog.Vault)
        case update(CompanyVaultCatalog.Vault, from: String)
        case remove(vaultId: String)
        case addManual(CompanyVaultCatalog.Manual)
        case replaceManual(CompanyVaultCatalog.Manual, previousRevision: String)
        case removeManual(vaultId: String, fileName: String)
        /// A change to a vault the open job is using waits for the job to close. `version` is the
        /// update waiting, nil for a removal or a change to its manuals.
        case waitForJob(vaultId: String, version: String?, removal: Bool)
        /// Manuals wait for Wi-Fi: `bytes` to download.
        case waitForWiFi(vaultId: String, bytes: Int64)
        /// The download needs `shortfall` more bytes free than the phone has.
        case notEnoughSpace(vaultId: String, shortfall: Int64)
        /// The catalog (nil) or one vault needs a newer build.
        case needsNewerApp(vaultId: String?, minBuild: Int)

        var vaultId: String? {
            switch self {
            case .install(let vault), .update(let vault, _): return vault.vaultId
            case .addManual(let manual), .replaceManual(let manual, _): return manual.vaultId
            case .remove(let id), .removeManual(let id, _), .waitForJob(let id, _, _), .waitForWiFi(let id, _),
                 .notEnoughSpace(let id, _): return id
            case .needsNewerApp(let id, _): return id
            }
        }
    }

    /// Room left beyond a download, so taking it never fills the phone: the plan needs the
    /// download's size twice (staging, then installed) plus this.
    static let spaceMargin: Int64 = 1_073_741_824

    static func needed(for bytes: Int64) -> Int64 { bytes * 2 + spaceMargin }

    static func steps(installed: Installed, catalog: CompanyVaultCatalog.Verified, conditions: Conditions) -> [Step] {
        if let minimum = conditions.minAppBuild, conditions.currentBuild < minimum {
            return [.needsNewerApp(vaultId: nil, minBuild: minimum)]
        }
        var steps: [Step] = []
        var free = conditions.freeBytes
        let listed = Set(catalog.vaults.map(\.vaultId))

        // A vault the company removed leaves after the job that is using it.
        for vaultId in installed.vaults.keys.sorted() where !listed.contains(vaultId) {
            // A row the phone refused is not a removal: its vault stays as it is.
            guard catalog.problems[vaultId] == nil else { continue }
            steps.append(conditions.job.uses(vaultId)
                         ? .waitForJob(vaultId: vaultId, version: nil, removal: true) : .remove(vaultId: vaultId))
        }

        // Vaults first: small, and on any network.
        var ready: [String] = []
        for vault in catalog.vaults {
            if let minimum = vault.minAppBuild, conditions.currentBuild < minimum {
                steps.append(.needsNewerApp(vaultId: vault.vaultId, minBuild: minimum))
                continue
            }
            let size = Int64(vault.sizeBytes)
            if let current = installed.vaults[vault.vaultId] {
                if current.version != vault.version || current.packId != vault.id {
                    guard !conditions.job.uses(vault.vaultId) else {
                        steps.append(.waitForJob(vaultId: vault.vaultId, version: vault.version, removal: false))
                        continue
                    }
                    guard free >= needed(for: size) else {
                        steps.append(.notEnoughSpace(vaultId: vault.vaultId, shortfall: needed(for: size) - free))
                        continue
                    }
                    free -= size
                    steps.append(.update(vault, from: current.version))
                }
            } else {
                // A new vault may arrive during a job: nothing the job uses changes.
                guard free >= needed(for: size) else {
                    steps.append(.notEnoughSpace(vaultId: vault.vaultId, shortfall: needed(for: size) - free))
                    continue
                }
                free -= size
                steps.append(.install(vault))
            }
            ready.append(vault.vaultId)
        }

        // Then manuals, one file at a time, vault by vault.
        for vaultId in ready {
            let wanted = catalog.manuals(in: vaultId)
            let have = installed.manuals[vaultId] ?? [:]
            let names = Set(wanted.map(\.fileName))
            // A manual row the phone refused is not a removal either.
            let removals = catalog.problems[vaultId] != nil ? [] : have.keys.filter { !names.contains($0) }.sorted()
            let downloads = wanted.filter { have[$0.fileName] != $0.revision }
            guard !removals.isEmpty || !downloads.isEmpty else { continue }
            guard !conditions.job.uses(vaultId) else {
                steps.append(.waitForJob(vaultId: vaultId, version: nil, removal: false))
                continue
            }
            steps.append(contentsOf: removals.map { .removeManual(vaultId: vaultId, fileName: $0) })
            guard !downloads.isEmpty else { continue }
            let bytes = downloads.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
            if conditions.network == .metered, !catalog.manualsOnAnyNetwork, !conditions.downloadNow.contains(vaultId) {
                steps.append(.waitForWiFi(vaultId: vaultId, bytes: bytes))
                continue
            }
            guard free >= needed(for: bytes) else {
                steps.append(.notEnoughSpace(vaultId: vaultId, shortfall: needed(for: bytes) - free))
                continue
            }
            free -= bytes
            for manual in downloads {
                if let previous = have[manual.fileName] {
                    steps.append(.replaceManual(manual, previousRevision: previous))
                } else {
                    steps.append(.addManual(manual))
                }
            }
        }
        return steps
    }
}

/// What a company vault's row under *Managed by ⟨org⟩* says. Pure, so the wording is tested.
struct CompanyVaultRow: Equatable, Identifiable, Sendable {
    let vaultId: String
    let name: String
    /// The installed version, or nil before it arrives.
    let version: String?
    let updatedAt: Date?
    /// The one line under the name: a named failure, what it waits for, or what is downloading.
    let status: String?
    /// Whether the row offers Download now (its manuals wait for Wi-Fi).
    let offersDownloadNow: Bool
    let isProblem: Bool

    var id: String { vaultId }

    /// The rows for a state and the catalog it was planned from, in the catalog's order, then any
    /// vault still installed that the catalog no longer lists.
    static func rows(state: CompanyVaultState, catalog: CompanyVaultCatalog.Verified?) -> [CompanyVaultRow] {
        var order = catalog?.vaults.map(\.vaultId) ?? []
        for id in state.vaults.keys.sorted() where !order.contains(id) { order.append(id) }
        for id in state.waits.keys.sorted() where !order.contains(id) { order.append(id) }
        for id in state.failures.keys.sorted() where !order.contains(id) && id != CompanyVaultState.catalogFailureKey {
            order.append(id)
        }
        return order.map { id in
            let installed = state.vaults[id]
            let listed = catalog?.vault(id)
            let name = installed?.name ?? listed?.name ?? id
            return CompanyVaultRow(vaultId: id, name: name, version: installed?.version, updatedAt: installed?.updatedAt,
                                   status: status(name: name, failure: state.failures[id], wait: state.waits[id],
                                                  downloading: state.downloading[id] ?? [], installed: installed != nil),
                                   offersDownloadNow: { if case .wifi? = state.waits[id] { return true }; return false }(),
                                   isProblem: state.failures[id] != nil || { if case .space? = state.waits[id] { return true }; return false }())
        }
    }

    static func status(name: String, failure: String?, wait: CompanyVaultState.Wait?, downloading: [String],
                       installed: Bool) -> String? {
        if let failure { return failure }
        switch wait {
        case .job(let version?, _)?:
            return String(localized: "Version \(version) ready — installs after this job.")
        case .job(nil, true)?:
            return String(localized: "Removed by your organisation — leaves this phone after this job.")
        case .job(nil, false)?:
            return String(localized: "Manual changes ready — they install after this job.")
        case .wifi(let bytes)?:
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(localized: "Manuals (\(size)) download on Wi-Fi.")
        case .space(let shortfall)?:
            let size = ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)
            return String(localized: "Not enough space for the \(name) manuals: \(size) needed.")
        case .newerApp(let build)?:
            return String(localized: "Needs a newer version of the app (build \(build) or later).")
        case nil:
            break
        }
        if !downloading.isEmpty {
            return downloading.count == 1
                ? String(localized: "Downloading \(downloading[0]).")
                : String(localized: "Downloading \(downloading.count) manuals.")
        }
        return installed ? nil : String(localized: "Installing.")
    }
}

/// Plan LR P1 — the line an answer carries while a vault's manual is still on its way, so an
/// answer that would have cited it says it is still downloading instead of answering without it.
enum CompanyVaultDownloads {
    static func promptNote(titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return "STILL DOWNLOADING: these manuals belong to this vault but have not reached this phone yet, so nothing from them can be quoted: "
            + titles.joined(separator: "; ")
            + ". If a question needs one of them, say that manual is still downloading to this phone rather than answering as if it were here."
    }

    /// The note for the vault a job is on, from what the enrolment record says is still to come.
    @MainActor
    static func promptNote(vaultId: String, manager: OrgProfileManager? = nil) -> String? {
        promptNote(titles: (manager ?? .shared).record?.companyVaults?.downloading[vaultId] ?? [])
    }
}
