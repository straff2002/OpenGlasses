import Foundation

/// Where approved team learnings live on a phone (Plan FP P2): the live entries that answer, and
/// the superseded and retracted ones kept as history.
///
/// One JSON file in Application Support beside the candidate store, loaded at construction and
/// written on every change. **It is the record, not the retrieval index**: what answers a question
/// is the entry's document in `DocumentStore` under `learning:<vaultId>` (`LearningCorpus`), and
/// a superseded or retracted entry stays here — the organisation keeps what it once believed,
/// which is an auditor's question — while its document leaves the namespace.
///
/// Registered in `DataStoreRegistry` as `learningEntries`. An approved entry has been read by a
/// reviewer whose job includes removing a customer's name, but a slip is still possible, so the
/// store is treated as able to hold one: complete protection, excluded from backup, walked by the
/// subject erasure, and cleared when the phone leaves its organisation.
@MainActor
final class LearningEntryStore {

    static let shared = LearningEntryStore()

    private(set) var entries: [LearningEntry]
    /// What bundles have been applied here (Plan FP P3): the newest per organisation label and
    /// direction, which an older bundle is refused against, and the retractions that arrived for
    /// entries this phone does not hold — tombstones a later copy of the content cannot outrun.
    private(set) var bundleLedger: LearningBundleLedger

    private let fileURL: URL
    private let ledgerURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("team-learning-entries.json")
        ledgerURL = folder.appendingPathComponent("team-learning-bundle-ledger.json")
        entries = Self.read(fileURL) ?? []
        bundleLedger = Self.readLedger(ledgerURL) ?? LearningBundleLedger()
        protectFile()
    }

    // MARK: - Reading

    func entry(id: String) -> LearningEntry? { entries.first { $0.id == id } }

    /// The entries that answer: neither superseded nor retracted.
    var live: [LearningEntry] { entries.filter(\.isLive) }

    /// The entry a corpus document id names (`LearningCorpus.documentId(entryID:vaultId:)`).
    func entry(forDocumentId documentId: String) -> LearningEntry? {
        LearningCorpus.entryID(fromDocumentId: documentId).flatMap(entry(id:))
    }

    // MARK: - Mutations

    /// Add or replace an entry by id.
    func upsert(_ entry: LearningEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// Replace the bundle ledger.
    func updateLedger(_ ledger: LearningBundleLedger) {
        bundleLedger = ledger
        saveLedger()
    }

    /// Everything, for a wipe — what the registry's "delete all" column names. The bundle ledger
    /// goes too: its tombstones carry retraction reasons.
    func removeAll() {
        entries = []
        save()
        bundleLedger = LearningBundleLedger()
        saveLedger()
    }

    /// Remove every entry whose words mention `token` — the subject erasure's call. Matched
    /// case-insensitively against the finding, symptom, fix, the text as captured, the subject and
    /// the approver, the fields a person's name could be in. Returns how many went.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let doomed = entries.filter { entry in
            [entry.finding, entry.symptom ?? "", entry.fix ?? "",
             entry.captured?.finding ?? "", entry.captured?.symptom ?? "", entry.captured?.fix ?? "",
             entry.subject.citationSubject, entry.approvedByName, entry.approvedByRole,
             entry.retractionReason ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let tombstones = bundleLedger.tombstones.filter { $0.reason.localizedCaseInsensitiveContains(needle) }
        if !tombstones.isEmpty {
            bundleLedger.tombstones.removeAll { tombstone in tombstones.contains(tombstone) }
            saveLedger()
        }
        guard !doomed.isEmpty else { return tombstones.count }
        let ids = Set(doomed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        save()
        return doomed.count + tombstones.count
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [LearningEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LearningEntry].self, from: data)
    }

    private static func readLedger(_ url: URL) -> LearningBundleLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LearningBundleLedger.self, from: data)
    }

    private func saveLedger() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundleLedger) else { return }
        try? data.write(to: ledgerURL, options: [.atomic, .completeFileProtection])
        protect(ledgerURL)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        protectFile()
    }

    /// Complete protection and no backup: a restored copy would put an organisation's approved
    /// findings — and anything review missed — onto a phone that may no longer belong to it.
    private func protectFile() {
        protect(fileURL)
        protect(ledgerURL)
    }

    private func protect(_ target: URL) {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        var url = target
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Where the file is, for the attribute-truth test.
    var fileLocation: URL { fileURL }
    /// Where the bundle ledger is.
    var ledgerLocation: URL { ledgerURL }
}

/// What a phone remembers about the team-learning bundles applied to it (Plan FP P3).
struct LearningBundleLedger: Codable, Equatable {

    /// The newest bundle applied for one organisation label and direction.
    struct Mark: Codable, Equatable {
        var issuedAt: Int64
        var sequence: Int64?
    }

    var marks: [String: Mark] = [:]
    /// Retractions for entries this phone does not hold.
    var tombstones: [LearningBundle.Retraction] = []

    init(marks: [String: Mark] = [:], tombstones: [LearningBundle.Retraction] = []) {
        self.marks = marks
        self.tombstones = tombstones
    }

    static func key(label: String?, direction: LearningBundle.Direction) -> String {
        "\(label ?? "")|\(direction.rawValue)"
    }

    /// Whether `bundle` is older than one already applied under its label and direction — by
    /// `sequence` when both carry one, else by `issuedAt`. The same bundle again is not older.
    func isOlder(_ bundle: LearningBundle) -> Bool {
        guard let mark = marks[Self.key(label: bundle.organisationLabel, direction: bundle.direction)] else {
            return false
        }
        if let arriving = bundle.sequence, let held = mark.sequence { return arriving < held }
        return bundle.issuedAt < mark.issuedAt
    }

    /// Record `bundle` as applied, keeping the newer mark.
    mutating func advance(for bundle: LearningBundle) {
        guard !isOlder(bundle) else { return }
        let key = Self.key(label: bundle.organisationLabel, direction: bundle.direction)
        let held = marks[key]
        marks[key] = Mark(issuedAt: max(bundle.issuedAt, held?.issuedAt ?? 0),
                          sequence: bundle.sequence ?? held?.sequence)
    }
}
