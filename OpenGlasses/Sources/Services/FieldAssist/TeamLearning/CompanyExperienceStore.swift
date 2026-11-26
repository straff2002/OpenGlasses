import Foundation

/// Plan NF P1 — each company vault's last applied crew experience set: the company's own fixes,
/// published from its sheet in the portal and delivered sealed on the company-vault catalog
/// (`Contracts/crew-experience.md` §6–7).
///
/// One JSON file in Application Support beside `LearningEntryStore`, loaded at construction and
/// written on every change. **It is the record, not the retrieval index**: what answers is each
/// entry's document under `learning:<vaultId>` (`LearningCorpus`), placed by a reconcile over the
/// union of this store and `LearningEntryStore` (`TeamLearningSources`), so applying a set never
/// removes a phone-reviewed entry and reviewing one never removes a set's.
///
/// A set is applied **whole** and only when it is newer than the one held; the last good set stays
/// whenever a read fails, and on a lapsed licence. Registered in `DataStoreRegistry` as
/// `companyExperience`: the portal's redaction is a floor, not a guarantee, so the store is
/// treated as able to hold a third party — first-unlock protection, no backup, walked by the
/// subject erasure, and cleared when the phone leaves its company.
@MainActor
final class CompanyExperienceStore {

    static let shared = CompanyExperienceStore()

    /// First-unlock, as `LearningEntryStore`: the pass that applies a set can run with the phone
    /// locked, and a `.complete` file refuses that write.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    nonisolated static let fileName = "company-experience-sets.json"

    /// One vault's applied set: what it was (for the next sequence check and the Custom Vaults
    /// line) and its entries, already in the phone's entry form.
    struct AppliedSet: Codable, Equatable {
        let profileId: String
        let vaultId: String
        let sequence: Int
        /// SHA-256 of the plaintext set, the catalog pointer's `revision`.
        let revision: String
        /// When the portal published it.
        let issuedAt: Date
        let appliedAt: Date
        var entries: [LearningEntry]
        /// Entries the set withdrew (`retracted[]`), by id: never published here.
        var retractedIDs: [String]
    }

    private(set) var sets: [String: AppliedSet]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(Self.fileName)
        sets = Self.read(fileURL) ?? [:]
        protect()
    }

    // MARK: - Reading

    func set(for vaultId: String) -> AppliedSet? { sets[vaultId] }

    /// Every entry of every applied set, vault by vault in id order.
    var entries: [LearningEntry] { sets.keys.sorted().flatMap { sets[$0]?.entries ?? [] } }

    func entry(id: String) -> LearningEntry? {
        for set in sets.values { if let found = set.entries.first(where: { $0.id == id }) { return found } }
        return nil
    }

    /// The entry a corpus document id names (`LearningCorpus.documentId(entryID:vaultId:)`).
    func entry(forDocumentId documentId: String) -> LearningEntry? {
        LearningCorpus.entryID(fromDocumentId: documentId).flatMap(entry(id:))
    }

    /// *Crew experience · 42 fixes · updated 25 Nov* for a vault that holds a set; nil otherwise.
    /// The date is the publish, in the phone's locale.
    func summaryLine(vaultId: String, locale: Locale = .current) -> String? {
        sets[vaultId].map { Self.summaryLine(count: $0.entries.count, updated: $0.issuedAt, locale: locale) }
    }

    nonisolated static func summaryLine(count: Int, updated: Date, locale: Locale = .current,
                                        timeZone: TimeZone = .current) -> String {
        let date = updated.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated))
        return count == 1
            ? String(localized: "Crew experience · 1 fix · updated \(date)",
                     comment: "A company vault's row in Custom Vaults: one fix from the company's crew experience sheet, and the day it was published")
            : String(localized: "Crew experience · \(count) fixes · updated \(date)",
                     comment: "A company vault's row in Custom Vaults: how many fixes from the company's crew experience sheet, and the day they were published")
    }

    // MARK: - Mutations

    /// Replace a vault's set whole.
    func apply(_ set: AppliedSet) {
        sets[set.vaultId] = set
        save()
    }

    /// A vault's set leaves: its company removed the vault, or the experience from it.
    func remove(vaultId: String) {
        guard sets.removeValue(forKey: vaultId) != nil else { return }
        save()
    }

    /// Everything, for a wipe or the phone leaving its company.
    func removeAll() {
        sets = [:]
        save()
    }

    /// Remove every entry whose words mention `token` — the subject erasure's call. Matched
    /// case-insensitively against the fields a person's name could be in. Returns how many went.
    /// The set's sequence stays, so the same set is not applied again over the erasure; a newer one is.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        var removed = 0
        for (vaultId, var set) in sets {
            let before = set.entries.count
            set.entries.removeAll { entry in
                [entry.finding, entry.symptom ?? "", entry.fix ?? "", entry.faultCode ?? "", entry.tried ?? "",
                 entry.outcome ?? "", entry.subject.citationSubject, entry.approvedByRole]
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            if set.entries.count != before {
                removed += before - set.entries.count
                sets[vaultId] = set
            }
        }
        if removed > 0 { save() }
        return removed
    }

    // MARK: - From the wire

    /// A set's entries in the phone's own form, the approver's role only (the portal publishes no
    /// name). A sheet row is a `recollection`, bound to no job until one confirms it. A learning an
    /// administrator approved in the portal (origin `spoken`, Plan NG P0b) is `.spoken`, with its
    /// candidate and jobs, so it is cited and introduced as a team learning, not as crew experience.
    /// `CrewExperienceSet.check` has already refused any other origin.
    nonisolated static func entries(of set: CrewExperienceSet) -> [LearningEntry] {
        set.entries.map { wire in
            let subject: LearningEntry.Subject
            switch wire.subject {
            case .model(let token, let manufacturer, let type):
                subject = .model(modelToken: token, manufacturer: manufacturer, equipmentType: type)
            case .symptom(let type, let phrase):
                subject = .symptom(equipmentType: type, phrase: phrase)
            }
            return LearningEntry(id: wire.entryID, subject: subject, vaultIDs: wire.vaultIDs, finding: wire.finding,
                                 symptom: wire.symptom, fix: wire.fix, faultCode: wire.faultCode, tried: wire.tried,
                                 outcome: wire.outcome, approvedAt: Date(timeIntervalSince1970: TimeInterval(wire.approvedAt)),
                                 approvedByRole: wire.approvedByRole, approvedByName: "",
                                 authorIsApprover: wire.authorIsApprover, contradictsSafetyNote: wire.contradictsSafetyNote,
                                 candidateID: wire.candidateID, origin: wire.isSpoken ? .spoken : .recollection,
                                 sourceJobIDs: wire.sourceJobIDs, confirmedJobCount: wire.confirmedJobCount)
        }
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [String: AppliedSet]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([String: AppliedSet].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sets) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        protect()
    }

    /// First-unlock protection and no backup: a restored copy would put a company's fixes onto a
    /// phone that may no longer belong to it.
    private func protect() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Where the file is, for the attribute-truth test.
    var fileLocation: URL { fileURL }
}

/// Plan NF P1 — every source of approved learnings on this phone, read as one, so the corpus
/// reconcile never forgets one source's documents for want of the other's entries (gotcha 2): the
/// phone-reviewed entries (Plan FP) and each company vault's crew experience set.
@MainActor
enum TeamLearningSources {

    /// The union, phone-reviewed entries first. A portal entry and a phone-reviewed one never
    /// share an id (the portal mints its own); were they ever to, the phone's own wins.
    static func entries(reviewed: LearningEntryStore, experience: CompanyExperienceStore) -> [LearningEntry] {
        let own = reviewed.entries
        let ids = Set(own.map(\.id))
        return own + experience.entries.filter { !ids.contains($0.id) }
    }

    /// The entry a corpus document names, from whichever source holds it.
    static func entry(forDocumentId documentId: String, reviewed: LearningEntryStore?,
                      experience: CompanyExperienceStore?) -> LearningEntry? {
        reviewed?.entry(forDocumentId: documentId) ?? experience?.entry(forDocumentId: documentId)
    }

    /// Make every `learning:` namespace exactly what the union says. Nothing is published under
    /// HIPAA mode; the namespaces are withheld from retrieval there anyway.
    static func reconcile(reviewed: LearningEntryStore, experience: CompanyExperienceStore,
                          vaults: [LearningCorpus.VaultTarget], store: DocumentStore, hipaa: Bool) {
        guard !hipaa else { return }
        LearningCorpus.reconcile(entries: entries(reviewed: reviewed, experience: experience), vaults: vaults, store: store)
    }
}
