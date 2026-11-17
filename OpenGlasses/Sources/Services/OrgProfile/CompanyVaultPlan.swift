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
        // Plan LV — optional, absent from a state written before them, which reads as before.
        /// The partner whose vault this is, as installed: "from ⟨name⟩".
        var publisherName: String? = nil
        /// The partner's own version number of what is installed: "version ⟨n⟩".
        var publisherVersion: Int? = nil
        /// A company layer: the vault id it adds files to.
        var extends: String? = nil
    }

    /// Plan LV: a published vault its partner took off this phone, for the notice that names them.
    struct RemovedPublished: Codable, Equatable, Sendable {
        var name: String
        var publisher: String
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
    /// Published vaults their partner removed from this phone (Plan LV), for the notice.
    var removedPublished: [RemovedPublished] = []
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
        removedPublished = (try? c.decodeIfPresent([RemovedPublished].self, forKey: .removedPublished)) ?? []
        lastCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    /// What the plan reads: the vaults and manuals installed, as recorded.
    var installed: CompanyVaultPlan.Installed {
        .init(vaults: vaults.mapValues { .init(packId: $0.packId, version: $0.version, extends: $0.extends) }, manuals: manuals)
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
        /// Plan LV: a company layer's base vault id; nil for every other vault.
        var extends: String? = nil
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
        // Plan LV: a company layer changes with its base. A job on the base uses the layer too.
        func inUse(_ vaultId: String, extends base: String?) -> Bool {
            conditions.job.uses(vaultId) || base.map(conditions.job.uses) == true
        }

        // A vault the company removed leaves after the job that is using it. Layers first, so a
        // layer never outlives the vault it adds to.
        let gone = installed.vaults.keys.filter { !listed.contains($0) }
            .sorted { (installed.vaults[$0]?.extends != nil ? 0 : 1, $0) < (installed.vaults[$1]?.extends != nil ? 0 : 1, $1) }
        for vaultId in gone {
            let base = installed.vaults[vaultId]?.extends
            // A row the phone refused is not a removal: its vault stays as it is. Except a layer
            // whose base has left: the layer goes with it (Plan LV).
            let baseLeft = base.map { !listed.contains($0) } ?? false
            guard catalog.problems[vaultId] == nil || baseLeft else { continue }
            steps.append(inUse(vaultId, extends: base)
                         ? .waitForJob(vaultId: vaultId, version: nil, removal: true) : .remove(vaultId: vaultId))
        }

        // Vaults first: small, and on any network. A company layer after the vault it extends,
        // and only once that vault is ready (Plan LV).
        let ordered = catalog.vaults.filter { !$0.isCompanyLayer } + catalog.vaults.filter(\.isCompanyLayer)
        var ready: [String] = []
        var baseChanged = Set<String>()
        for vault in ordered {
            if let minimum = vault.minAppBuild, conditions.currentBuild < minimum {
                steps.append(.needsNewerApp(vaultId: vault.vaultId, minBuild: minimum))
                continue
            }
            if let base = vault.extends, !ready.contains(base) {
                // The vault it extends is not here yet, or waits: the layer waits with it, and says
                // so when what holds it is the open job.
                let current = installed.vaults[vault.vaultId]
                let pending = current == nil || (!vault.isFrozen && (current?.version != vault.version || current?.packId != vault.id))
                if pending, inUse(vault.vaultId, extends: base) {
                    steps.append(.waitForJob(vaultId: vault.vaultId, version: vault.version, removal: false))
                }
                continue
            }
            let size = Int64(vault.sizeBytes)
            if let current = installed.vaults[vault.vaultId] {
                // Plan LV: a frozen vault's publisher has ended. The phone keeps the version it has
                // and compares none; its manuals, the company's own, still follow below. A layer is
                // laid again over a base that changed, so it is checked against the new base.
                let changed = current.version != vault.version || current.packId != vault.id
                    || vault.extends.map(baseChanged.contains) == true
                if !vault.isFrozen, changed {
                    guard !inUse(vault.vaultId, extends: vault.extends) else {
                        steps.append(.waitForJob(vaultId: vault.vaultId, version: vault.version, removal: false))
                        continue
                    }
                    guard free >= needed(for: size) else {
                        steps.append(.notEnoughSpace(vaultId: vault.vaultId, shortfall: needed(for: size) - free))
                        continue
                    }
                    free -= size
                    steps.append(.update(vault, from: current.version))
                    baseChanged.insert(vault.vaultId)
                }
            } else {
                // A new vault may arrive during a job: nothing the job uses changes. A new layer
                // changes the vault the job is on, so it waits.
                if vault.isCompanyLayer, inUse(vault.vaultId, extends: vault.extends) {
                    steps.append(.waitForJob(vaultId: vault.vaultId, version: vault.version, removal: false))
                    continue
                }
                guard free >= needed(for: size) else {
                    steps.append(.notEnoughSpace(vaultId: vault.vaultId, shortfall: needed(for: size) - free))
                    continue
                }
                free -= size
                steps.append(.install(vault))
                baseChanged.insert(vault.vaultId)
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

    // Plan LV — published vaults. Nil on every other vault's row, which reads as before.

    /// "from ⟨partner⟩ · version ⟨n⟩": whose vault this is, and the partner's own version.
    var byline: String? = nil
    /// "No longer updated by ⟨partner⟩ · version ⟨n⟩ kept", for a vault whose partner has ended.
    var frozenNote: String? = nil
    /// A company layer: "Adds to ⟨vault⟩".
    var layerNote: String? = nil
    /// The manuals the vault was written against, against the ones this phone holds.
    var checklist: ManualChecklist? = nil

    var id: String { vaultId }

    /// What a published vault's row says about its expected manuals, and the list it opens.
    struct ManualChecklist: Equatable, Sendable {
        /// "9 of 12 manuals · 2 a different revision · 1 missing".
        let summary: String
        let entries: [Entry]
        /// Whether any expected manual is missing or held at another revision.
        let hasDifferences: Bool

        struct Entry: Equatable, Identifiable, Sendable {
            let id: String
            /// The manual's title, with its edition when the vault names one.
            let title: String
            /// "On this phone", "A different revision", "Missing".
            let status: String
            let state: ExpectedManualMatch.Status
        }

        static func make(_ summary: ExpectedManualMatch.Summary) -> ManualChecklist? {
            guard summary.expectedCount > 0 else { return nil }
            var parts = [String(localized: "\(summary.heldCount) of \(summary.expectedCount) manuals")]
            if summary.differentRevisionCount > 0 {
                parts.append(String(localized: "\(summary.differentRevisionCount) a different revision"))
            }
            if summary.missingCount > 0 { parts.append(String(localized: "\(summary.missingCount) missing")) }
            let entries = summary.entries.map { entry -> Entry in
                let title = entry.expected.edition.map { String(localized: "\(entry.expected.title) (\($0))") }
                    ?? entry.expected.title
                let status: String
                switch entry.status {
                case .matched: status = String(localized: "On this phone")
                case .differentRevision: status = String(localized: "A different revision")
                case .missing: status = String(localized: "Missing")
                }
                return Entry(id: entry.expected.key, title: title, status: status, state: entry.status)
            }
            return ManualChecklist(summary: parts.joined(separator: " · "), entries: entries,
                                   hasDifferences: summary.differentRevisionCount + summary.missingCount > 0)
        }
    }

    /// The rows for a state and the catalog it was planned from, in the catalog's order, then any
    /// vault still installed that the catalog no longer lists. `documents` are the manuals each
    /// installed vault holds, for a published vault's checklist.
    static func rows(state: CompanyVaultState, catalog: CompanyVaultCatalog.Verified?,
                     documents: (String) -> [VaultDocument] = { _ in [] }) -> [CompanyVaultRow] {
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
            var row = CompanyVaultRow(vaultId: id, name: name, version: installed?.version, updatedAt: installed?.updatedAt,
                                      status: status(name: name, failure: state.failures[id], wait: state.waits[id],
                                                     downloading: state.downloading[id] ?? [], installed: installed != nil),
                                      offersDownloadNow: { if case .wifi? = state.waits[id] { return true }; return false }(),
                                      isProblem: state.failures[id] != nil || { if case .space? = state.waits[id] { return true }; return false }())
            // The partner as installed, else as listed: the version people talk about is the one
            // on this phone.
            let partner = installed?.publisherName ?? listed?.publisher?.name
            let partnerVersion = installed?.publisherVersion ?? (installed == nil ? listed?.publisher?.version : nil)
            if let partner {
                row.byline = partnerVersion.map { String(localized: "from \(partner) · version \($0)") }
                    ?? String(localized: "from \(partner)")
                if listed?.isFrozen == true, installed != nil {
                    row.frozenNote = partnerVersion.map { String(localized: "No longer updated by \(partner) · version \($0) kept") }
                        ?? String(localized: "No longer updated by \(partner)")
                }
            }
            if let base = listed?.extends ?? installed?.extends {
                let baseName = state.vaults[base]?.name ?? catalog?.vault(base)?.name ?? base
                row.layerNote = String(localized: "Adds to \(baseName)")
            }
            if installed != nil, let expects = listed?.expects, !expects.isEmpty {
                row.checklist = ManualChecklist.make(ExpectedManualMatch.match(expects: expects, documents: documents(id)))
            }
            return row
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

/// Plan LR P1 — the line an answer carries while a vault's manual is not on this phone yet, so an
/// answer that would have cited it says so instead of answering without it, and says why: a
/// manual held for the open job, or one whose download failed, is not "still downloading".
enum CompanyVaultDownloads {
    /// Why listed manuals are not here, as the vault's row has it.
    enum Reason: Equatable, Sendable {
        case downloading
        /// Held: the app changes no vault the open job uses until it ends.
        case afterJob
        case onWiFi
        case noSpace
        case newerApp
        /// The last pass could not download them; the next launch or foreground tries again.
        case failed

        static func of(wait: CompanyVaultState.Wait?, failed: Bool) -> Reason {
            switch wait {
            case .job?: return .afterJob
            case .wifi?: return .onWiFi
            case .space?: return .noSpace
            case .newerApp?: return .newerApp
            case nil: return failed ? .failed : .downloading
            }
        }
    }

    static func promptNote(titles: [String], reason: Reason = .downloading) -> String? {
        guard !titles.isEmpty else { return nil }
        let say: String
        switch reason {
        case .downloading:
            say = "They are downloading now. If a question needs one of them, say that manual is still downloading to this phone rather than answering as if it were here."
        case .afterJob:
            say = "They are held until this job ends, because the app does not change a vault during a job, and they download once it is finished. If a question needs one of them, say that manual reaches this phone after this job; do not say it is downloading."
        case .onWiFi:
            say = "They wait for Wi-Fi. If a question needs one of them, say that manual downloads when this phone is on Wi-Fi, or straight away with Download now in Settings, Organisation; do not say it is downloading."
        case .noSpace:
            say = "This phone does not have enough free space for them. If a question needs one of them, say that manual can't download until space is freed on this phone; do not say it is downloading."
        case .newerApp:
            say = "They need a newer version of the app. If a question needs one of them, say that manual needs the app to be updated first; do not say it is downloading."
        case .failed:
            say = "The last try to download them failed, and the app tries again each time it is opened. If a question needs one of them, say that manual hasn't downloaded to this phone and that Settings, Organisation shows why; do not say it is still downloading."
        }
        return "NOT ON THIS PHONE YET: these manuals belong to this vault but have not reached this phone, so nothing from them can be quoted: "
            + titles.joined(separator: "; ") + ". " + say
    }

    /// The note for the vault a job is on, from what the enrolment record says is still to come
    /// and what the vault's row says it waits for.
    @MainActor
    static func promptNote(vaultId: String, manager: OrgProfileManager? = nil) -> String? {
        let state = (manager ?? .shared).record?.companyVaults
        return promptNote(titles: state?.downloading[vaultId] ?? [],
                          reason: .of(wait: state?.waits[vaultId], failed: state?.failures[vaultId] != nil))
    }
}
